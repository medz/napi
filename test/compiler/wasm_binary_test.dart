import 'dart:io';

import 'package:napi/src/build/build.dart';
import 'package:test/test.dart';

void main() {
  test(
    'binary-only modules load without structural container exports',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'napi-wasm-binary-only-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final input = await File('${directory.path}/business.dart')
          .writeAsString('''
import 'dart:typed_data';
import 'package:napi/napi.dart';
@NAPI() Uint8List bytes(Uint8List value) => value;
@NAPI() ByteBuffer buffer(ByteBuffer value) => value;
@NAPI() Uint8List owned() => Uint8List.fromList([3, 4]);
''');
      await buildLibrary(
        library: input.uri,
        output: Directory('${directory.path}/module'),
        packagesPath: File('.dart_tool/package_config.json').absolute.path,
      );
      await File('${directory.path}/check.mjs').writeAsString(r'''
import assert from 'node:assert/strict';
import * as api from './module/module.wasm';
const source = new Uint8Array([1, 2]);
const bytes = api.bytes(source);
const buffer = api.buffer(source.buffer);
source.fill(9);
assert.deepEqual([...bytes], [1, 2]);
assert.deepEqual([...new Uint8Array(buffer)], [1, 2]);
assert.notEqual(bytes.buffer, source.buffer);
assert.notEqual(buffer, source.buffer);
assert.deepEqual([...api.owned()], [3, 4]);
assert.equal(api.bytes(new Uint8Array(0)).length, 0);
assert.equal(api.buffer(new ArrayBuffer(0)).byteLength, 0);
assert.throws(() => api.bytes(new Uint16Array(1)), TypeError);
''');
      final result = await Process.run('node', [
        'check.mjs',
      ], workingDirectory: directory.path);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      final boundary = await File('${directory.path}/module/boundary.mjs')
          .readAsString();
      expect(boundary, isNot(contains('function visitStructure(')));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'nested-only binary modules include their private snapshot adapter',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'napi-wasm-binary-nested-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final input = await File('${directory.path}/business.dart')
          .writeAsString('''
import 'dart:typed_data';
import 'package:napi/napi.dart';
@NAPI() List<Uint8List?> nested(List<Uint8List?> value) => value;
''');
      await buildLibrary(
        library: input.uri,
        output: Directory('${directory.path}/module'),
        packagesPath: File('.dart_tool/package_config.json').absolute.path,
      );
      await File('${directory.path}/check.mjs').writeAsString(r'''
import assert from 'node:assert/strict';
import * as api from './module/module.wasm';
const source = new Uint8Array([1, 2]);
const result = api.nested([source, null]);
source[0] = 9;
assert.deepEqual([...result[0]], [1, 2]);
assert.equal(result[1], null);
assert.notEqual(result[0].buffer, source.buffer);
''');
      final result = await Process.run('node', [
        'check.mjs',
      ], workingDirectory: directory.path);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'Wasm binary snapshots isolate storage through direct and async exports',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'napi-wasm-binary-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final input = await File('${directory.path}/business.dart')
          .writeAsString('''
import 'dart:async';
import 'dart:typed_data';
import 'package:napi/napi.dart';
Uint8List? saved;
@NAPI() Uint8List remember(Uint8List value) { saved = value; return value; }
@NAPI() int readSaved(int index) => saved![index];
@NAPI() int writeSaved(int index, int value) { saved![index] = value; return value; }
@NAPI() Uint8List owned() => Uint8List.sublistView(Uint8List.fromList([8, 9, 10, 11]), 1, 3);
@NAPI() ByteBuffer buffer(ByteBuffer value) => value;
@NAPI() ByteBuffer ownedBuffer() => Uint8List.fromList([1, 2, 3, 4, 5, 6, 7]).buffer;
@NAPI() Uint8List ownedWindow(int length, bool readOnly) {
  final backing = Uint8List.fromList(List.generate(length + 2, (i) => (i * 31 + 128) & 255));
  final window = Uint8List.sublistView(backing, 1, length + 1);
  return readOnly ? window.asUnmodifiableView() : window;
}
@NAPI() Uint8List? optional([Uint8List? value]) => value;
@NAPI() List<Uint8List> nested(List<Uint8List> value) => value;
@NAPI() ({Uint8List bytes, ByteBuffer buffer}) record(Uint8List value, ByteBuffer backing) => (bytes: value, buffer: backing);
@NAPI() Future<Uint8List> later(Uint8List value) async {
  await Future<void>.delayed(Duration(milliseconds: 5));
  return value;
}
@NAPI() Stream<Uint8List> items(Uint8List value) async* {
  yield value;
  value[0]++;
  yield value;
}
''');
      await buildLibrary(
        library: input.uri,
        output: Directory('${directory.path}/module'),
        packagesPath: File('.dart_tool/package_config.json').absolute.path,
      );
      await File('${directory.path}/check.mjs').writeAsString(r'''
import assert from 'node:assert/strict';
import vm from 'node:vm';
import * as api from './module/module.wasm';
const backing = new ArrayBuffer(8);
const source = new Uint8Array(backing, 2, 3);
source.set([1, 2, 3]);
const result = api.remember(source);
assert.deepEqual([...result], [1, 2, 3]);
assert.notEqual(result.buffer, backing);
source[0] = 40;
result[1] = 50;
assert.equal(api.readSaved(0), 1);
assert.equal(api.readSaved(1), 2);
api.writeSaved(2, 60);
assert.equal(source[2], 3);
assert.equal(result[2], 3);
assert.deepEqual([...api.owned()], [9, 10]);
assert.deepEqual([...new Uint8Array(api.ownedBuffer())], [1, 2, 3, 4, 5, 6, 7]);
for (let length = 0; length <= 9; length++) {
  const expected = Array.from({length}, (_, i) => ((i + 1) * 31 + 128) & 255);
  for (const readOnly of [false, true]) {
    assert.deepEqual([...api.ownedWindow(length, readOnly)], expected);
  }
  const input = new Uint8Array(length + 2);
  input.set(expected, 1);
  const output = api.remember(input.subarray(1, length + 1));
  input.fill(0);
  assert.deepEqual([...output], expected);
}
const bufferCopy = api.buffer(backing);
assert.notEqual(bufferCopy, backing);
assert.deepEqual(new Uint8Array(bufferCopy), new Uint8Array(backing));
const foreign = vm.runInNewContext('new Uint8Array(new ArrayBuffer(8), 3, 2)');
foreign.set([12, 13]);
assert.deepEqual([...api.remember(foreign)], [12, 13]);
assert.deepEqual(new Uint8Array(api.buffer(foreign.buffer)), new Uint8Array(foreign.buffer));

const shadow = new Uint8Array([21, 22]);
for (const name of ['buffer', 'byteOffset', 'byteLength', 'length']) {
  Object.defineProperty(shadow, name, {get() {throw new Error('shadowed ' + name);}});
}
assert.deepEqual([...api.remember(shadow)], [21, 22]);
const repeats = api.nested([source, source]);
assert.notEqual(repeats[0].buffer, repeats[1].buffer);
repeats[0][0] = 70;
assert.equal(repeats[1][0], 40);
const record = api.record(source, backing);
assert.deepEqual([...record.bytes], [40, 2, 3]);
assert.deepEqual(new Uint8Array(record.buffer), new Uint8Array(backing));
assert.equal(api.optional(), null);
assert.equal(api.optional(undefined), null);
assert.equal(api.optional(null), null);
assert.throws(() => api.remember(new Uint16Array(1)), TypeError);

const pendingInput = new Uint8Array([31, 32]);
const pending = api.later(pendingInput);
pendingInput[0] = 90;
structuredClone(pendingInput.buffer, {transfer: [pendingInput.buffer]});
assert.deepEqual([...(await pending)], [31, 32]);
const events = api.items(new Uint8Array([41, 42]));
const first = await events.next();
const second = await events.next();
assert.deepEqual([...first.value], [41, 42]);
assert.deepEqual([...second.value], [42, 42]);
assert.equal((await events.next()).done, true);

// Private metadata stabilizes SDK access; public snapshots regain JS semantics.
const typed = Object.getPrototypeOf(Uint8Array.prototype);
const restores = [];
const protectedSource = new Uint8Array([99, 40, 2, 3, 4, 5, 6, 7, 99]).subarray(1, 8);
let protectedList;
let protectedBuffer;
let protectedOwned;
let protectedOwnedBuffer;
try {
  for (const [owner, names] of [
    [typed, ['buffer', 'byteOffset', 'byteLength', 'length']],
    [ArrayBuffer.prototype, ['byteLength']],
    [DataView.prototype, ['buffer', 'byteOffset', 'getUint32', 'setUint32']],
  ]) {
    for (const name of names) {
      const descriptor = Object.getOwnPropertyDescriptor(owner, name);
      restores.push(() => Object.defineProperty(owner, name, descriptor));
      Object.defineProperty(owner, name, {configurable: true, get() {throw new Error('replaced ' + name);}});
    }
  }
  protectedList = api.remember(protectedSource);
  protectedBuffer = api.buffer(backing);
  protectedOwned = api.ownedWindow(7, true);
  protectedOwnedBuffer = api.ownedBuffer();
} finally {for (const restore of restores.reverse()) restore();}
assert.deepEqual([...protectedList], [40, 2, 3, 4, 5, 6, 7]);
assert.deepEqual(new Uint8Array(protectedBuffer), new Uint8Array(backing));
assert.deepEqual([...protectedOwned], [159, 190, 221, 252, 27, 58, 89]);
assert.deepEqual([...new Uint8Array(protectedOwnedBuffer)], [1, 2, 3, 4, 5, 6, 7]);

const originalDataView = globalThis.DataView;
let constructions = 0;
let guardedCopy;
try {
  globalThis.DataView = new Proxy(originalDataView, {
    construct(target, args, newTarget) {
      if (++constructions > 1) throw new Error('copy added a dynamic DataView construction');
      return Reflect.construct(target, args, newTarget);
    },
  });
  guardedCopy = api.ownedWindow(7, true);
} finally {globalThis.DataView = originalDataView;}
assert.deepEqual([...guardedCopy], [159, 190, 221, 252, 27, 58, 89]);

for (const output of [result, protectedList]) {
  for (const name of ['buffer', 'byteOffset', 'byteLength', 'length']) assert.equal(Object.hasOwn(output, name), false);
  assert.equal(Object.hasOwn(output.buffer, 'byteLength'), false);
  structuredClone(output.buffer, {transfer: [output.buffer]});
  assert.equal(output.byteLength, 0);
  assert.equal(output.length, 0);
}
assert.equal(Object.hasOwn(protectedBuffer, 'byteLength'), false);
structuredClone(protectedBuffer, {transfer: [protectedBuffer]});
assert.equal(protectedBuffer.byteLength, 0);
''');
      final result = await Process.run('node', [
        'check.mjs',
      ], workingDirectory: directory.path);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
