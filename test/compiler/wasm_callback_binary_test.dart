import 'dart:io';

import 'package:napi/src/build/build.dart';
import 'package:test/test.dart';

void main() {
  test('Wasm callbacks copy binary values and retain shared windows', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'napi-wasm-callback-binary-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final input = await File('${temporary.path}/business.dart')
        .writeAsString('''
import 'dart:typed_data';
import 'package:napi/napi.dart';
typedef Payload = ({List<Uint8List?> bytes, ByteBuffer? buffer, List<SharedBytes?> shared});
Uint8List? saved;
ByteBuffer? savedBuffer;
SharedBytes? savedShared;
Payload? savedPayload;
Payload payload() {
  final shared = SharedBytes.allocate(2);
  shared[0] = 5;
  return (bytes: [Uint8List.fromList([6, 7]), null],
    buffer: Uint8List.fromList([8, 9]).buffer, shared: [shared, null]);
}
int save(Payload source, Payload result) {
  savedPayload = result;
  source.bytes.first![0] = 60;
  source.buffer!.asUint8List()[0] = 80;
  return readPayload();
}
@NAPI() int bytes(Uint8List Function(Uint8List) callback) {
  final source = Uint8List.fromList([1, 2]);
  saved = callback(source);
  source[0] = 9;
  return saved![0];
}
@NAPI() int readByte(int index) => saved![index];
@NAPI() int nullable(Uint8List? Function(Uint8List?) callback) => callback(null) == null ? 1 : 0;
@NAPI() int buffer(ByteBuffer Function(ByteBuffer) callback) {
  final source = Uint8List.fromList([3, 4]);
  savedBuffer = callback(source.buffer);
  source[0] = 9;
  return savedBuffer!.asUint8List()[0];
}
@NAPI() int readBuffer() => savedBuffer!.asUint8List()[0];
@NAPI() Future<int> laterBuffer(Future<ByteBuffer> Function() callback) async {
  savedBuffer = await callback();
  return readBuffer();
}
@NAPI() int shared(SharedBytes Function(SharedBytes) callback) {
  final source = SharedBytes.allocate(2);
  source[0] = 11;
  savedShared = callback(source);
  savedShared![1] = 12;
  return identical(source, savedShared) ? 1 : 0;
}
@NAPI() int readShared() => savedShared![0];
@NAPI() int nested(Payload Function(Payload) callback) {
  final source = payload();
  return save(source, callback(source));
}
@NAPI() Future<int> later(Future<Payload> Function(Payload) callback) async {
  final source = payload();
  return save(source, await callback(source));
}
@NAPI() int readPayload() => savedPayload!.bytes.first![0] +
  savedPayload!.buffer!.asUint8List()[0] + savedPayload!.shared.first![0];
''');
    await buildLibrary(
      library: input.uri,
      output: Directory('${temporary.path}/module'),
      packagesPath: File('.dart_tool/package_config.json').absolute.path,
    );
    await File('${temporary.path}/check.mjs').writeAsString(r'''
import assert from 'node:assert/strict';
import {runInNewContext} from 'node:vm';
import * as api from './module/module.wasm';
let argument;
assert.equal(api.bytes(value => { argument = value; return value; }), 1);
assert.deepEqual([...argument], [1, 2], 'Dart writes cannot alter callback snapshots');
argument[0] = 90;
assert.equal(api.readByte(0), 1, 'callback results own independent snapshots');
assert.equal(api.nullable(value => { assert.equal(value, null); return null; }), 1);
assert.throws(() => api.nullable(() => undefined), TypeError);
assert.equal(api.buffer(value => { argument = value; return value; }), 3);
assert.deepEqual([...new Uint8Array(argument)], [3, 4]);
new Uint8Array(argument)[0] = 90;
assert.equal(api.readBuffer(), 3);
const foreign = runInNewContext('new Uint8Array([21, 22])');
assert.equal(api.bytes(() => foreign), 21);
foreign[0] = 90;
assert.equal(api.readByte(0), 21);
let shared;
assert.equal(api.shared(value => { shared = value; value[0] = 13; return value; }), 1);
assert.deepEqual([...shared], [13, 12]);
shared[0] = 14;
assert.equal(api.readShared(), 14);
for (const invoke of [callback => api.nested(callback), callback => api.later(async value => callback(value))]) {
  let source, result;
  assert.equal(await invoke(value => {
    source = value;
    assert.equal(value.bytes[1], null);
    assert.equal(value.shared[1], null);
    result = {bytes: [new Uint8Array([20]), null], buffer: new Uint8Array([30]).buffer,
      shared: [value.shared[0], null]};
    return result;
  }), 55);
  assert.deepEqual([...source.bytes[0]], [6, 7]);
  assert.deepEqual([...new Uint8Array(source.buffer)], [8, 9]);
  result.bytes[0][0] = 90;
  new Uint8Array(result.buffer)[0] = 90;
  result.shared[0][0] = 9;
  assert.equal(api.readPayload(), 59, 'nested snapshots isolate writes while shared data remains live');
}
const output = new Uint8Array([31, 32]);
assert.equal(await api.laterBuffer(async () => output.buffer), 31);
output[0] = 90;
assert.equal(api.readBuffer(), 31);
for (const wrong of [new Uint16Array(1), {}, null, undefined]) {
  assert.throws(() => api.bytes(() => wrong), TypeError);
  assert.throws(() => api.buffer(() => wrong), TypeError);
  assert.throws(() => api.shared(() => wrong), TypeError);
  await assert.rejects(api.laterBuffer(async () => wrong), TypeError);
}
const detached = new Uint8Array([1]);
structuredClone(detached.buffer, {transfer: [detached.buffer]});
assert.throws(() => api.bytes(() => detached), /detached/);
assert.throws(() => api.buffer(() => detached.buffer), /detached/);
if (typeof SharedArrayBuffer === 'function') {
  const shared = new Uint8Array(new SharedArrayBuffer(2));
  assert.throws(() => api.bytes(() => shared), /SharedArrayBuffer/);
  assert.throws(() => api.shared(() => shared), /SharedArrayBuffer/);
}
''');
    final execution = await Process.run('node', [
      'check.mjs',
    ], workingDirectory: temporary.path);
    expect(
      execution.exitCode,
      0,
      reason: '${execution.stdout}${execution.stderr}',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}
