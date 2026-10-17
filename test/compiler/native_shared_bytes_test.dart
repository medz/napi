import 'dart:io';

import 'package:napi/build.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/native/entrypoint.dart';
import 'package:napi/src/compiler/native/loader.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

const _source = '''
import 'dart:typed_data';
import 'package:napi/napi.dart';
typedef Bytes = SharedBytes;
Bytes? saved;
WeakReference<Bytes>? weak;
List<int> pressure = [];
@NAPI() Bytes remember(Bytes value) {
  saved = value; weak = WeakReference(value); return value;
}
@NAPI() bool same(Bytes value) => identical(saved, value);
@NAPI() Bytes? optional([Bytes? value]) => value;
@NAPI() Bytes allocate(int length) => SharedBytes.allocate(length);
@NAPI() int length() => saved!.length;
@NAPI() int read(int index) => saved![index];
@NAPI() int write(int index, int value) { saved![index] = value; return value; }
@NAPI() Bytes subview(int start, [int? end]) => saved!.subview(start, end);
@NAPI() Uint8List snapshot([int start = 0, int? end]) => saved!.toUint8List(start, end);
@NAPI() int bulk(Uint8List source, int offset) { saved!.write(source, offset: offset); return 1; }
@NAPI() int copy(Bytes source, int sourceOffset, int targetOffset, int? length) {
  saved!.copyFrom(source, sourceOffset: sourceOffset, targetOffset: targetOffset, length: length);
  return 1;
}
@NAPI() List<Bytes?> nested(List<Bytes?> value) => value;
@NAPI() Map<Bytes, Bytes> mapping(Map<Bytes, Bytes> value) => value;
@NAPI() Future<Bytes> later(Bytes value, int milliseconds) async {
  await Future<void>.delayed(Duration(milliseconds: milliseconds)); return value;
}
@NAPI() Stream<Bytes> events(Bytes value) => Stream.value(value);
@NAPI() int drop() { saved = null; return 0; }
@NAPI() bool alive() => weak?.target != null;
@NAPI() int gc(int seed) { pressure = List.generate(500000, (i) => i + seed); return pressure.last; }
@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new')
class Payload { Payload(this.bytes); final Bytes bytes; }
@NAPI() Payload payload(Payload value) => value;
@NAPI() class Holder { Holder(this.bytes); Bytes bytes; }
''';

const _internal = '''
import 'package:napi/napi.dart';
@NAPI() int compute(int size) {
  final bytes = SharedBytes.allocate(size);
  if (size > 0) bytes[0] = 17;
  return size == 0 ? bytes.length : bytes[0];
}
@NAPI() Future<int> later(int size) async {
  await Future<void>.delayed(const Duration(milliseconds: 1));
  return compute(size);
}
@NAPI() class Internal {
  final int value;
  Internal(int size) : value = compute(size);
}
''';

void main() {
  test('ordinary native loader includes lazy shared allocation only', () {
    final loader = emitNativeLoader(['compute']);
    expect(loader, contains(r'$napiAllocateSharedBytes'));
    expect(loader, contains('arguments.length === 3 && kind === 2'));
    expect(loader, isNot(contains(r'$napiObserveCallbackPromise')));
    expect(loader, isNot(contains('target => deliver')));
  });

  test(
    'shared aliases and internal-only allocation compile as Dart AOT',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'napi-shared-aot-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final packages = File('.dart_tool/package_config.json').absolute.path;
      for (final (index, business) in [_source, _internal].indexed) {
        final source = await File('${directory.path}/business$index.dart')
            .writeAsString(business);
        final plan = validateNative(
          await AnnotationFrontend(
            packagesPath: packages,
            native: true,
          ).read(source.uri),
        );
        expect(plan.hasSharedBytesTypes, index == 0);
        final entry = await File('${directory.path}/entry$index.dart')
            .writeAsString(emitNativeDart(plan));
        expect(
          await entry.readAsString(),
          contains('installSharedBytesAllocator(_api.allocateSharedBytes)'),
        );
        final result = await Process.run(Platform.resolvedExecutable, [
          'compile',
          'aot-snapshot',
          '--packages=$packages',
          entry.path,
          '--output=${directory.path}/module$index.aot',
        ]);
        expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  final runtime = Platform.environment['NAPI_TEST_NATIVE_RUNTIME'];
  test(
    'native shared windows retain identity and checked host storage',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'napi-shared-native-',
      );
      final directory = Directory(await temporary.resolveSymbolicLinks());
      addTearDown(() => directory.delete(recursive: true));
      for (final (index, business) in [_source, _internal].indexed) {
        final source = await File('${directory.path}/business$index.dart')
            .writeAsString(business);
        await buildLibrary(
          library: source.uri,
          output: Directory('${directory.path}/built$index'),
          packagesPath: File('.dart_tool/package_config.json').absolute.path,
          target: BuildTarget.native,
          nativeRuntime: Directory(runtime!),
        );
      }
      final script = await File('${directory.path}/check.mjs')
          .writeAsString(r'''
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {setImmediate, setTimeout} from 'node:timers/promises';
import * as api from './built0/module.mjs';
import * as internal from './built1/module.mjs';
assert.equal(internal.compute(4), 17);
assert.equal(internal.compute(0), 0);
assert.equal(await internal.later(3), 17);
assert.equal(new internal.Internal(2).value, 17);
assert.throws(() => internal.compute(-1), RangeError);
const bytes = Buffer.from([1, 2, 3, 4, 5, 6]).subarray(1, 5);
assert.equal(api.remember(bytes), bytes);
assert(api.same(bytes));
assert.equal(api.length(), 4);
bytes[0] = 21; assert.equal(api.read(0), 21);
api.write(1, 22); assert.equal(bytes[1], 22);
const snapshot = api.snapshot(0, 2);
assert.deepEqual([...snapshot], [21, 22]);
api.write(0, 31); assert.equal(snapshot[0], 21);
const sub = api.subview(1, 3);
assert.equal(sub.buffer, bytes.buffer);
assert.equal(sub.byteOffset, bytes.byteOffset + 1);
assert.equal(sub.length, 2);
sub[0] = 41; assert.equal(api.read(1), 41);
api.bulk(new Uint8Array([51, 52]), 1);
assert.deepEqual([...bytes], [31, 51, 52, 5]);
api.copy(bytes, 0, 1, 3);
assert.deepEqual([...bytes], [31, 31, 51, 52]);
assert.throws(() => api.snapshot(-1), RangeError);
assert.throws(() => api.bulk(new Uint8Array([1]), 4), RangeError);
assert.throws(() => api.copy(bytes, -1, 0, 1), RangeError);
assert.throws(() => api.write(0, 256), RangeError);
assert.throws(() => api.read(4), RangeError);
assert.equal(api.optional(), null); assert.equal(api.optional(null), null);
assert.equal(api.nested([bytes, null, bytes])[2], bytes);
assert.equal(api.mapping(new Map([[bytes, bytes]])).get(bytes), bytes);
assert.equal(api.payload({bytes}).bytes, bytes);
const holder = new api.Holder(bytes); assert.equal(holder.bytes, bytes);
const fresh = api.allocate(2); assert.deepEqual([...fresh], [0, 0]);
holder.bytes = fresh; assert.equal(holder.bytes, fresh);
const foreign = vm.runInNewContext('new Uint8Array([61, 62])');
assert.equal(api.remember(foreign), foreign); assert.equal(api.read(0), 61);
assert.equal(await api.later(foreign, 1), foreign);
const stream = api.events(foreign);
foreign[0] = 63;
assert.equal((await stream.next()).value, foreign);
assert.equal((await stream.next()).done, true);
const rab = new ArrayBuffer(8, {maxByteLength: 16});
const tracking = new Uint8Array(rab, 2), fixed = new Uint8Array(rab, 2, 3);
assert.equal(api.remember(tracking), tracking);
assert.equal(api.length(), 6); rab.resize(12); assert.equal(api.length(), 10);
api.remember(fixed); rab.resize(3);
assert.throws(() => api.length(), TypeError);
assert.throws(() => api.same(fixed), TypeError);
rab.resize(8); assert.equal(api.length(), 3); assert(api.same(fixed));
for (const invalid of [new Uint16Array(1), new Uint8Array(new SharedArrayBuffer(1)), new Proxy(new Uint8Array(1), {})]) {
  assert.throws(() => api.remember(invalid), TypeError);
}
const empty = new Uint8Array(0); api.remember(empty);
assert.equal(api.length(), 0); structuredClone(empty.buffer, {transfer: [empty.buffer]});
assert.throws(() => api.length(), TypeError);
const detach = api.allocate(1); api.remember(detach);
const pending = api.later(detach, 10);
structuredClone(detach.buffer, {transfer: [detach.buffer]});
assert.throws(() => api.read(0), TypeError);
await assert.rejects(pending, TypeError);
api.drop();
let retained = api.allocate(1); api.remember(retained);
const weak = new WeakRef(retained); retained = null;
for (let i=0;i<6;i++) { await setImmediate(); api.gc(i); global.gc(); await setTimeout(3); }
assert(weak.deref()); assert(api.alive());
api.drop();
let collected = false;
for (let i=0;i<60;i++) {
  await setImmediate(); api.gc(i); global.gc(); await setTimeout(3);
  if (!weak.deref() && !api.alive()) { collected = true; break; }
}
assert(collected);
''');
      final result = await Process.run(
        Platform.environment['NAPI_TEST_NODE'] ?? 'node',
        ['--expose-gc', script.path],
      );
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    },
    skip: runtime == null
        ? 'Set NAPI_TEST_NATIVE_RUNTIME to an ABI15 bundle.'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
