import 'dart:io';

import 'package:napi/src/build/build.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Wasm shared windows preserve live storage and retained identity',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'napi-shared-wasm-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final source = await File('${temporary.path}/business.dart')
          .writeAsString('''
import 'dart:typed_data';
import 'package:napi/napi.dart';
typedef Bytes = SharedBytes;
Bytes? saved;
WeakReference<Bytes>? weak;
@NAPI() Bytes remember(Bytes value) { saved = value; weak = WeakReference(value); return value; }
@NAPI() bool same(Bytes value) => identical(saved, value);
@NAPI() bool alive() => weak?.target != null;
@NAPI() int drop() { saved = null; return 0; }
@NAPI() Bytes allocate(int length) => SharedBytes.allocate(length);
@NAPI() int length() => saved!.length;
@NAPI() int read(int index) => saved![index];
@NAPI() int put(int index, int byte) { saved![index] = byte; return byte; }
@NAPI() Bytes view(int start, [int? end]) => saved!.subview(start, end);
@NAPI() Uint8List snapshot([int start = 0, int? end]) => saved!.toUint8List(start, end);
@NAPI() int write(Uint8List source, int offset) { saved!.write(source, offset: offset); return 1; }
@NAPI() int writeOwned(int length, int offset, bool readOnly) {
  final backing = Uint8List.fromList(List.generate(length + 2, (i) => (i * 31 + 128) & 255));
  final window = Uint8List.sublistView(backing, 1, length + 1);
  saved!.write(readOnly ? window.asUnmodifiableView() : window, offset: offset);
  window.fillRange(0, length, 0);
  return 1;
}
@NAPI() int copy(Bytes source, int start, int offset, int? length) {
  saved!.copyFrom(source, sourceOffset: start, targetOffset: offset, length: length); return 1;
}
@NAPI() Bytes? optional([Bytes? value]) => value;
@NAPI() List<Bytes?> nested(List<Bytes?> value) => value;
@NAPI() Future<Bytes> later(Bytes value) async {
  await Future<void>.delayed(Duration(milliseconds: 5)); return value;
}
@NAPI() Future<int> delayedRead() async {
  await Future<void>.delayed(Duration(milliseconds: 5)); return saved![0];
}
@NAPI() Stream<Bytes> events(Bytes value) async* { yield value; yield value; }
@NAPI() int caught() { try { return saved![0]; } catch (error) { return -1; } }
@NAPI(classPolicy: ClassPolicy.value)
class Payload { Payload(this.bytes); final Bytes bytes; }
@NAPI() Payload payload(Payload value) => value;
@NAPI() class Holder { Holder(this.bytes); Bytes bytes; }
class FakeBytes implements SharedBytes {
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
@NAPI() SharedBytes fakeOutput() => FakeBytes();
@NAPI() int fakeCopy() { saved!.copyFrom(FakeBytes()); return 0; }
''');
      await buildLibrary(
        library: source.uri,
        output: Directory('${temporary.path}/module'),
        packagesPath: File('.dart_tool/package_config.json').absolute.path,
      );
      await File('${temporary.path}/check.mjs').writeAsString(r'''
import assert from 'node:assert/strict';
import vm from 'node:vm';
import * as api from './module/module.wasm';
const source = new Uint8Array([1, 2, 3, 4]);
assert.equal(api.remember(source), source);
assert.equal(api.same(source), true);
assert.throws(() => api.fakeOutput(), TypeError);
assert.throws(() => api.fakeCopy(), TypeError);
source[0] = 9;
assert.equal(api.read(0), 9);
api.put(1, 8);
assert.equal(source[1], 8);
const sub = api.view(1, 3);
assert.equal(sub.buffer, source.buffer);
assert.equal(sub.byteOffset, 1);
assert.deepEqual([...sub], [8, 3]);
const snapshot = api.snapshot(1, 3);
source[1] = 7;
assert.deepEqual([...snapshot], [8, 3]);
api.write(new Uint8Array([11, 12]), 1);
assert.deepEqual([...source], [9, 11, 12, 4]);
api.copy(source, 0, 1, 3);
assert.deepEqual([...source], [9, 9, 11, 12]);
assert.throws(() => api.copy(source, 0, 1, 4), RangeError);
assert.throws(() => api.read(2 ** 32), RangeError);
assert.throws(() => api.put(0, 256), RangeError);
assert.throws(() => api.view(0, -1), RangeError);
assert.equal(api.optional(), null);
assert.equal(api.optional(undefined), null);
assert.equal(api.optional(null), null);
assert.equal(api.optional(source), source);
assert.deepEqual(api.nested([source, null, source]), [source, null, source]);
assert.equal(api.payload({bytes: source}).bytes, source);
const owner = new api.Holder(source);
assert.equal(owner.bytes, source);
const fresh = api.allocate(3);
assert.deepEqual([...fresh], [0, 0, 0]);
assert.equal(Object.hasOwn(fresh, 'length'), false);
assert.throws(() => api.allocate(-1), RangeError);
assert.throws(() => api.allocate(2 ** 32), RangeError);
for (let length = 0; length <= 9; length++) {
  const expected = Array.from({length}, (_, i) => ((i + 1) * 31 + 128) & 255);
  const backing = new Uint8Array(length + 4).fill(90);
  api.remember(backing.subarray(1, length + 3));
  const input = new Uint8Array(length + 2);
  input.set(expected, 1);
  api.write(input.subarray(1, length + 1), 1);
  input.fill(0);
  assert.deepEqual([...backing], [90, 90, ...expected, 90, 90]);
  for (const readOnly of [false, true]) {
    backing.fill(90);
    api.writeOwned(length, 1, readOnly);
    assert.deepEqual([...backing], [90, 90, ...expected, 90, 90]);
  }
}
const foreign = vm.runInNewContext('new Uint8Array(new ArrayBuffer(8), 3, 2)');
assert.equal(api.remember(foreign), foreign);
api.put(0, 41);
assert.equal(foreign[0], 41);
for (const invalid of [new Uint16Array(2), new DataView(new ArrayBuffer(2)), new Proxy(source, {}), new Uint8Array(new SharedArrayBuffer(2)), new Uint8Array(new SharedArrayBuffer(2, {maxByteLength: 4}))]) {
  assert.throws(() => api.remember(invalid), TypeError);
}
const rab = new ArrayBuffer(8, {maxByteLength: 16});
const tracking = new Uint8Array(rab, 2);
const fixed = new Uint8Array(rab, 2, 4);
api.remember(tracking);
const fixedSubview = api.view(1);
rab.resize(12);
assert.equal(api.length(), 10);
assert.equal(fixedSubview.length, 5);
api.remember(fixed);
rab.resize(3);
assert.throws(() => api.length(), TypeError);
assert.throws(() => api.read(0), TypeError);
assert.equal(api.caught(), -1);
rab.resize(8);
assert.equal(api.length(), 4);
const empty = new Uint8Array(new ArrayBuffer(0));
api.remember(empty);
assert.equal(api.length(), 0);
structuredClone(empty.buffer, {transfer: [empty.buffer]});
assert.throws(() => api.length(), TypeError);
const deferred = new Uint8Array([31]);
assert.equal(await api.later(deferred), deferred);
api.remember(deferred);
const pending = api.delayedRead();
structuredClone(deferred.buffer, {transfer: [deferred.buffer]});
await assert.rejects(pending, TypeError);
const streamValue = new Uint8Array([51]);
Object.defineProperty(streamValue, 'then', {get() {throw new Error('item then');}});
const stream = api.events(streamValue);
const first = await stream.next();
assert.equal(first.value, streamValue);
streamValue[0] = 52;
assert.equal(first.value[0], 52);
assert.equal((await stream.next()).value, streamValue);
await stream.return();

// Live metadata is always read using captures; no own getters or species.
const shadow = new Uint8Array([61, 62]);
for (const name of ['length', 'byteOffset', 'byteLength', 'buffer', 'constructor']) {
  Object.defineProperty(shadow, name, {get() {throw new Error('shadow ' + name);}});
}
api.remember(shadow);
assert.equal(api.length(), 2);
assert.deepEqual([...api.snapshot()], [61, 62]);
const typed = Object.getPrototypeOf(Uint8Array.prototype);
const protectedTarget = new Uint8Array(10).fill(90);
api.remember(protectedTarget);
const restores = [];
try {
  for (const [owner, names] of [
    [typed, ['length', 'byteOffset', 'byteLength', 'buffer', 'at', 'set']],
    [DataView.prototype, ['buffer', 'byteOffset', 'getUint32', 'setUint32']],
  ]) {
    for (const name of names) {
      const descriptor = Object.getOwnPropertyDescriptor(owner, name);
      restores.push(() => Object.defineProperty(owner, name, descriptor));
      Object.defineProperty(owner, name, {configurable: true, get() {throw new Error('prototype ' + name);}});
    }
  }
  assert.equal(api.length(), 10);
  api.put(0, 63);
  assert.equal(api.snapshot()[0], 63);
  api.write(new Uint8Array([64, 65, 66, 67, 68, 69, 70]), 1);
  for (let i = 0; i < 7; i++) assert.equal(api.read(i + 1), 64 + i);
  api.writeOwned(7, 1, true);
} finally {
  for (const restore of restores.reverse()) restore();
}
assert.deepEqual([...protectedTarget], [63, 159, 190, 221, 252, 27, 58, 89, 90, 90]);

// Keeping the original JS view alone does not pin its Dart adapter.
const retainedView = new Uint8Array([71]);
api.remember(retainedView);
api.drop();
for (let i = 0; i < 30 && api.alive(); i++) {
  await new Promise(resolve => setTimeout(resolve, 0));
  global.gc();
  await new Promise(resolve => setTimeout(resolve, 0));
}
assert.equal(api.alive(), false);
assert.equal(api.remember(retainedView), retainedView);
assert.equal(api.same(retainedView), true);
''');
      final result = await Process.run('node', [
        '--expose-gc',
        'check.mjs',
      ], workingDirectory: temporary.path);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('Wasm installs allocation for an ordinary scalar-only module', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'napi-shared-internal-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final source = await File('${temporary.path}/business.dart')
        .writeAsString('''
import 'dart:typed_data';
import 'package:napi/napi.dart';
@NAPI() int defaults(int size) {
  final source = SharedBytes.allocate(size);
  final target = SharedBytes.allocate(size);
  source.write(Uint8List(size)..fillRange(0, size, 7));
  target.copyFrom(source);
  final snapshot = source.toUint8List();
  final explicit = source.toUint8List(0, null);
  final emptyCopy = source.toUint8List(size);
  final view = source.subview(0);
  final emptyView = source.subview(size, null);
  target.copyFrom(source, sourceOffset: size, targetOffset: size);
  return snapshot.length + explicit.length + emptyCopy.length + view.length + emptyView.length + target.length + (size == 0 ? 0 : target[0]);
}
@NAPI() Future<int> laterDefaults(int size) async {
  await Future<void>.delayed(const Duration(milliseconds: 1));
  return defaults(size);
}
@NAPI() int compute(int size) {
  final bytes = SharedBytes.allocate(size);
  if (size > 0) bytes[0] = 17;
  return size == 0 ? bytes.length : bytes[0];
}
@NAPI() Future<int> later(int size) async {
  await Future<void>.delayed(const Duration(milliseconds: 1));
  return compute(size);
}
@NAPI() class Internal { Internal(int size): value = compute(size); final int value; }
''');
    await buildLibrary(
      library: source.uri,
      output: Directory('${temporary.path}/module'),
      packagesPath: File('.dart_tool/package_config.json').absolute.path,
    );
    await File('${temporary.path}/check.mjs').writeAsString(r'''
import assert from 'node:assert/strict';
import * as api from './module/module.wasm';
assert.equal(new api.Internal(2).value, 17);
assert.equal(api.compute(2), 17);
assert.equal(api.compute(0), 0);
assert.equal(await api.later(2), 17);
assert.equal(api.defaults(0), 0);
assert.equal(api.defaults(4), 23);
assert.equal(await api.laterDefaults(4), 23);
assert.throws(() => api.compute(-1), RangeError);
await assert.rejects(api.later(-1), RangeError);
''');
    final result = await Process.run('node', [
      'check.mjs',
    ], workingDirectory: temporary.path);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
