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
typedef Bytes = Uint8List;
Bytes? saved;
@NAPI() Bytes remember(Bytes value) { saved = value; return value; }
@NAPI() int savedByte(int index) => saved![index];
@NAPI() Bytes? optional([Bytes? value]) => value;
@NAPI() ByteBuffer buffer(ByteBuffer value) => value;
@NAPI() ByteBuffer ownedBuffer() => Uint16List.fromList([0x1234]).buffer;
@NAPI() Bytes owned() => Uint8List.sublistView(
  Uint8List.fromList([1, 2, 3, 4]), 1, 3).asUnmodifiableView();
@NAPI() ByteBuffer unmodifiableBuffer() => owned().buffer;
@NAPI() List<Bytes?> nested(List<Bytes?> value) => value;
@NAPI() Map<String, Bytes> mapping(Map<String, Bytes> value) => value;
@NAPI() Future<Bytes> later(Bytes value) async => value;
@NAPI() Stream<ByteBuffer> events(ByteBuffer value) => Stream.value(value);
@NAPI(classPolicy: ClassPolicy.value)
class Payload {
  Payload(this.bytes);
  final Bytes bytes;
}
@NAPI() Payload payload(Payload value) => value;
@NAPI() class Holder {
  Holder(this.bytes);
  Bytes bytes;
}
''';

void main() {
  test(
    'binary-only loader enables validation without incoming callback queue',
    () {
      final ordinary = emitNativeLoader(['remember']);
      expect(ordinary, isNot(contains(r'$napiBinaryView')));
      final binary = emitNativeLoader(['remember'], hasBinary: true);
      expect(binary, contains(r'$napiBinaryView'));
      expect(binary, contains('arguments.length === 4'));
      expect(binary, isNot(contains('const deliver =')));
    },
  );

  test('binary aliases and nested payloads compile as Dart AOT', () async {
    final directory = await Directory.systemTemp.createTemp('napi-binary-aot-');
    addTearDown(() => directory.delete(recursive: true));
    final source = await File('${directory.path}/business.dart')
        .writeAsString(_source);
    final packages = File('.dart_tool/package_config.json').absolute.path;
    final plan = validateNative(
      await AnnotationFrontend(
        packagesPath: packages,
        native: true,
      ).read(source.uri),
    );
    expect(plan.hasBinary, true);
    final entry = await File('${directory.path}/entry.dart')
        .writeAsString(emitNativeDart(plan));
    final result = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'aot-snapshot',
      '--packages=$packages',
      entry.path,
      '--output=${directory.path}/module.aot',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  }, timeout: const Timeout(Duration(minutes: 2)));

  final runtime = Platform.environment['NAPI_TEST_NATIVE_RUNTIME'];
  test(
    'native bulk snapshots preserve view windows and independent storage',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'napi-binary-native-',
      );
      final directory = Directory(await temporary.resolveSymbolicLinks());
      addTearDown(() => directory.delete(recursive: true));
      final source = await File('${directory.path}/business.dart')
          .writeAsString(_source);
      await buildLibrary(
        library: source.uri,
        output: Directory('${directory.path}/built'),
        packagesPath: File('.dart_tool/package_config.json').absolute.path,
        target: BuildTarget.native,
        nativeRuntime: Directory(runtime!),
      );
      final script = await File('${directory.path}/check.mjs')
          .writeAsString(r'''
import assert from 'node:assert/strict';
import vm from 'node:vm';
import * as api from './built/module.mjs';
const input = Buffer.from([8, 9, 10, 11]).subarray(1, 3);
const output = api.remember(input);
assert.deepEqual([...output], [9, 10]);
input[0] = 70;
output[1] = 80;
assert.equal(api.savedByte(0), 9);
assert.equal(api.savedByte(1), 10);
assert.equal(api.remember(new Uint8Array(0)).length, 0);
assert.equal(api.buffer(new ArrayBuffer(0)).byteLength, 0);
assert.deepEqual([...api.owned()], [2, 3]);
assert.deepEqual([...new Uint16Array(api.ownedBuffer())], [0x1234]);
assert.deepEqual([...new Uint8Array(api.unmodifiableBuffer())], [1, 2, 3, 4]);
const foreign = vm.runInNewContext('new Uint8Array([21, 22])');
assert.deepEqual([...api.remember(foreign)], [21, 22]);
const copy = api.buffer(foreign.buffer);
assert.notEqual(copy, foreign.buffer);
assert.deepEqual([...new Uint8Array(copy)], [21, 22]);
const repeated = api.nested([foreign, null, foreign]);
repeated[0][0] = 0;
assert.equal(repeated[1], null);
assert.equal(repeated[2][0], 21);
assert.equal(api.mapping(new Map([['x', foreign]])).get('x')[0], 21);
assert.equal(api.payload({bytes: foreign}).bytes[0], 21);
const holder = new api.Holder(foreign);
holder.bytes = new Uint8Array([31]);
assert.equal(holder.bytes[0], 31);
assert.equal(api.optional(), null);
assert.equal(api.optional(null), null);
const pending = api.later(foreign);
structuredClone(foreign.buffer, {transfer: [foreign.buffer]});
assert.deepEqual([...(await pending)], [21, 22]);
assert.throws(() => api.remember(foreign), TypeError);
const stream = api.events(new Uint8Array([41]).buffer);
assert.deepEqual([...new Uint8Array((await stream.next()).value)], [41]);
assert.equal((await stream.next()).done, true);
const resizable = new ArrayBuffer(8, {maxByteLength: 16});
const fixed = new Uint8Array(resizable, 2, 3);
fixed.set([51, 52, 53]);
assert.deepEqual([...api.remember(fixed)], [51, 52, 53]);
resizable.resize(3);
assert.throws(() => api.remember(fixed), TypeError);
for (const invalid of [new Uint16Array(1), new Uint8Array(new SharedArrayBuffer(1)), new Proxy(new Uint8Array(1), {})]) {
  assert.throws(() => api.remember(invalid), TypeError);
}
''');
      final result = await Process.run(
        Platform.environment['NAPI_TEST_NODE'] ?? 'node',
        [script.path],
      );
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    },
    skip: runtime == null
        ? 'Set NAPI_TEST_NATIVE_RUNTIME to an ABI15 bundle.'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
