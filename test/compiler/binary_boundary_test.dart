import 'dart:io';

import 'package:napi/src/compiler/emit/js/binary.dart';
import 'package:test/test.dart';

void main() {
  test('binary intrinsics preserve windows, snapshots and invalidation', () async {
    final directory = await Directory.systemTemp.createTemp('napi-binary-');
    addTearDown(() => directory.delete(recursive: true));
    await File('${directory.path}/binary.mjs').writeAsString(
      '$binaryPolicy\n$wasmBinaryPolicy\nexport {\$napiBinaryView as view, \$napiCopyBinary as copy};',
    );
    await File('${directory.path}/check.mjs').writeAsString(r'''
import assert from 'node:assert/strict';
import {runInNewContext} from 'node:vm';
import {view, copy, allocateBinary, finishBinary} from './binary.mjs';
const input = new Uint8Array([10, 20, 30, 40, 50]).subarray(1, 4);
const copied = copy(input, 0, false, 'input');
assert.deepEqual([...copied], [20, 30, 40]);
assert.equal(copied.byteOffset, 0);
assert.equal(copied.buffer.byteLength, 3);
input[0] = 90;
assert.equal(copied[0], 20);
copied[1] = 80;
assert.equal(input[1], 30);
assert.notEqual(copy(input, 0, false, 'repeat').buffer, copied.buffer);
const live = view(input, 0, false, 'live');
assert.equal(live.buffer, input.buffer);
assert.equal(live.byteOffset, input.byteOffset);
assert.equal(live.byteLength, input.byteLength);
const buffer = Buffer.from([1, 2, 3, 4]).subarray(1, 3);
assert.deepEqual([...copy(buffer, 0, false, 'buffer')], [2, 3]);
const raw = new Uint8Array([4, 5, 6]).buffer;
const rawCopy = copy(raw, 1, false, 'raw');
assert.deepEqual([...new Uint8Array(rawCopy)], [4, 5, 6]);
assert.notEqual(rawCopy, raw);
new Uint8Array(raw)[1] = 9;
assert.equal(new Uint8Array(rawCopy)[1], 5);
for (const kind of [0, 1]) {
  const empty = kind === 0 ? new Uint8Array(0) : new ArrayBuffer(0);
  assert.equal(view(empty, kind, false, 'empty').byteLength, 0);
  assert.equal(copy(null, kind, true, 'nullable'), null);
  for (const wrong of [null, undefined, 1, 'x', {}, [], new Proxy(empty, {})]) {
    assert.throws(() => copy(wrong, kind, false, 'bad'), /^TypeError: bad: expected/);
  }
}
for (const wrong of [new Uint8ClampedArray(3), new Uint16Array(3), new DataView(raw)]) {
  assert.throws(() => copy(wrong, 0, false, 'bad'), /expected Uint8Array/);
}
assert.throws(() => copy(new SharedArrayBuffer(3), 1, false, 'bad'), /expected ArrayBuffer/);
assert.throws(() => copy(new Uint8Array(new SharedArrayBuffer(3)), 0, false, 'bad'), /SharedArrayBuffer/);
assert.throws(() => copy(new Uint8Array(new SharedArrayBuffer(3, {maxByteLength: 10})), 0, false, 'bad'), /SharedArrayBuffer/);
const foreign = runInNewContext('new Uint8Array([7, 8, 9]).subarray(1)');
assert.deepEqual([...copy(foreign, 0, false, 'foreign')], [8, 9]);
assert.deepEqual([...new Uint8Array(copy(foreign.buffer, 1, false, 'foreign'))], [7, 8, 9]);
let touched = 0;
for (const key of ['buffer', 'byteOffset', 'byteLength', 'length', 'constructor']) {
  Object.defineProperty(input, key, {get() { touched++; throw Error('shadow'); }});
}
Object.defineProperty(input, Symbol.iterator, {get() { touched++; throw Error('iterator'); }});
assert.deepEqual([...copy(input, 0, false, 'shadowed')], [90, 30, 40]);
Object.defineProperty(raw, 'byteLength', {get() { touched++; throw Error('shadow'); }});
assert.deepEqual([...new Uint8Array(copy(raw, 1, false, 'shadowed'))], [4, 9, 6]);
assert.equal(touched, 0);
const detached = new ArrayBuffer(4);
const detachedView = new Uint8Array(detached);
structuredClone(detached, {transfer: [detached]});
assert.throws(() => copy(detached, 1, false, 'detached'), /detached or out-of-bounds/);
assert.throws(() => copy(detachedView, 0, false, 'detached'), /detached or out-of-bounds/);
const detachedEmpty = new ArrayBuffer(0);
structuredClone(detachedEmpty, {transfer: [detachedEmpty]});
assert.throws(() => copy(detachedEmpty, 1, false, 'empty'), /detached or out-of-bounds/);
const rab = new ArrayBuffer(8, {maxByteLength: 16});
const fixed = new Uint8Array(rab, 2, 4);
const tracking = new Uint8Array(rab, 2);
fixed.set([1, 2, 3, 4]);
const beforeResize = copy(fixed, 0, false, 'fixed');
rab.resize(4);
assert.throws(() => copy(fixed, 0, false, 'fixed'), /detached or out-of-bounds/);
assert.deepEqual([...copy(tracking, 0, false, 'tracking')], [1, 2]);
assert.deepEqual([...beforeResize], [1, 2, 3, 4]);
rab.resize(8);
assert.deepEqual([...copy(fixed, 0, false, 'fixed')], [1, 2, 0, 0]);
const proto = Object.getPrototypeOf(Uint8Array.prototype);
const restore = [];
function replace(object, key) {
  const previous = Object.getOwnPropertyDescriptor(object, key);
  restore.push(() => Object.defineProperty(object, key, previous));
  Object.defineProperty(object, key, {configurable: true, get() { throw Error('poisoned ' + key); }});
}
let privateView;
try {
  for (const key of ['buffer', 'byteOffset', 'byteLength', 'length', 'at', 'set']) replace(proto, key);
  replace(ArrayBuffer.prototype, 'byteLength');
  privateView = copy(foreign, 0, false, 'private', true);
  assert.equal(privateView.length, 2);
  assert.equal(privateView.byteOffset, 0);
  assert.equal(privateView.byteLength, 2);
  assert.equal(privateView.buffer.byteLength, 2);
  assert.equal(privateView[0], 8);
} finally { for (const reset of restore.reverse()) reset(); }
assert.deepEqual([...privateView], [8, 9]);
const output = allocateBinary(3);
output[1] = 7;
assert.equal(finishBinary(output, 0), output);
for (const key of ['buffer', 'length', 'byteLength', 'byteOffset']) assert.equal(Object.hasOwn(output, key), false);
assert.equal(Object.hasOwn(output.buffer, 'byteLength'), false);
structuredClone(output.buffer, {transfer: [output.buffer]});
assert.equal(output.length, 0);
assert.equal(output.byteLength, 0);
const outputBytes = allocateBinary(2);
const outputBuffer = finishBinary(outputBytes, 1);
assert.equal(outputBuffer, outputBytes.buffer);
assert.equal(Object.hasOwn(outputBuffer, 'byteLength'), false);
structuredClone(outputBuffer, {transfer: [outputBuffer]});
assert.equal(outputBuffer.byteLength, 0);
Object.defineProperty(Object.prototype, 'get', {configurable: true, value() { throw Error('inherited descriptor getter'); }});
try {
  const safe = copy(foreign, 0, false, 'private', true);
  assert.equal(safe[0], 8);
  assert.equal(safe.length, 2);
  const allocated = allocateBinary(2);
  assert.equal(finishBinary(allocated, 0), allocated);
  assert.equal(Object.hasOwn(allocated, 'length'), false);
} finally { delete Object.prototype.get; }
const iterator = Array.prototype[Symbol.iterator];
const privateOutput = allocateBinary(2);
try {
  Array.prototype[Symbol.iterator] = function* () {};
  finishBinary(privateOutput, 0);
} finally { Array.prototype[Symbol.iterator] = iterator; }
for (const key of ['buffer', 'length', 'byteLength', 'byteOffset']) assert.equal(Object.hasOwn(privateOutput, key), false);
assert.equal(Object.hasOwn(privateOutput.buffer, 'byteLength'), false);
structuredClone(privateOutput.buffer, {transfer: [privateOutput.buffer]});
assert.equal(privateOutput.byteLength, 0);
for (const length of [-1, 0.5, NaN, Infinity, 0x80000000]) assert.throws(() => allocateBinary(length), RangeError);
''');
    final result = await Process.run('node', [
      'check.mjs',
    ], workingDirectory: directory.path);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  });
}
