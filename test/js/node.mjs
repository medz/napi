import assert from 'node:assert/strict';
import { setImmediate as immediate } from 'node:timers/promises';
import { runInNewContext } from 'node:vm';
import * as api from '@napi/integration';
import * as subpath from '@napi/integration/module.wasm';
import * as relative from './dist/module.wasm';
import { runAssertions } from './assertions.mjs';

const publicNames = [
  'identityBool', 'identityInt', 'identityDouble', 'identityString', 'identityBytes',
  'incrementFirst', 'nullableBool', 'nullableInt', 'nullableDouble', 'nullableString',
  'nullableBytes', 'oversizedInt', 'throwError', 'throwRange', 'throwArgument',
  'readFile', 'response', 'instantiate', '$napiReadFile', 'fetch', 'URL', 'Error',
  'incrementCounter', 'counter', 'countedAdd', 'conditionalProfile',
  'wildcardSingle', 'wildcardRepeated', 'wildcardMixed',
];
for (const name of publicNames) {
  assert.equal(typeof api[name], 'function', `${name} is a named function export`);
  assert.equal(api[name], relative[name], `${name} resolves to the same Wasm instance`);
  assert.equal(api[name], subpath[name], `${name} subpath resolves to the same Wasm instance`);
  assert.match(Function.prototype.toString.call(api[name]), /\[native code\]/,
    `${name} is a raw Wasm function`);
}
const checks = runAssertions(api);
assert.equal(api.wildcardSingle(1), 42);
assert.equal(api.wildcardRepeated(1, 'unused'), 'ignored');
assert.equal(api.wildcardMixed(1, 7, 'unused', true, 9), '7:true:9');
assert.throws(() => api.wildcardSingle(), (error) =>
  error instanceof TypeError && error.message.startsWith('parameter _: '));
assert.throws(() => api.wildcardSingle('1'), TypeError);
assert.throws(() => api.wildcardSingle(1.5), TypeError);
assert.throws(() => api.wildcardSingle(Number.MAX_SAFE_INTEGER + 1), (error) =>
  error instanceof RangeError && error.message.includes('parameter _: '));
assert.throws(() => api.wildcardRepeated(1), TypeError);
assert.throws(() => api.wildcardRepeated(1, 2), TypeError);
assert.throws(() => api.wildcardMixed(1, 7, undefined, true, 9), TypeError);
assert.equal(api.wildcardSingle(2), 42, 'wildcard calls recover after input errors');
assert.equal(api.wildcardRepeated(2, 'valid'), 'ignored');
assert.equal(api.wildcardMixed(2, 9, 'valid', false, 7), '9:false:7');
assert.equal(relative.identityInt(42), 42);
assert.equal(relative.identityString('relative 你好'), 'relative 你好');
assert.deepEqual(relative.identityBytes(new Uint8Array([1, 128, 255])), new Uint8Array([1, 128, 255]));
assert.deepEqual(api.identityBytes(Buffer.from([1, 128, 255])), new Uint8Array([1, 128, 255]));
assert.deepEqual(api.identityBytes(runInNewContext('new Uint8Array([5, 128, 255])')), new Uint8Array([5, 128, 255]));

// A type probe failure is an original JS exception, not an owned-copy failure.
const originalApply = Reflect.apply;
const reflection = new TypeError('byte kind reflection');
const byteInput = new Uint8Array([1, 2]);
try {
  Reflect.apply = () => { throw reflection; };
  assert.throws(() => api.identityBytes(byteInput), (error) => error === reflection);
} finally {
  Reflect.apply = originalApply;
}
const OriginalUint8Array = globalThis.Uint8Array;
try {
  for (const reason of [new RangeError('byte copy range'), new Error('byte copy JS'), Symbol('byte copy'), { original: true }]) {
    globalThis.Uint8Array = class { constructor() { throw reason; } };
    assert.throws(() => api.identityBytes(byteInput), (error) => error === reason);
  }
  const copyError = new TypeError('owned copy');
  globalThis.Uint8Array = class { constructor() { throw copyError; } };
  assert.throws(() => api.identityBytes(byteInput), (error) =>
    error instanceof TypeError && error !== copyError && error.message === 'parameter value: owned copy');
  const diagnosticFailure = { message: 'copy diagnostic failed' };
  for (const descriptor of [
    { get() { throw diagnosticFailure; } },
    { value: { toString() { throw diagnosticFailure; } } },
  ]) {
    const original = new TypeError('original copy failure');
    Object.defineProperty(original, 'message', descriptor);
    globalThis.Uint8Array = class { constructor() { throw original; } };
    assert.throws(() => api.identityBytes(byteInput), (error) => error === original);
  }
} finally {
  globalThis.Uint8Array = OriginalUint8Array;
}
assert.deepEqual(api.identityBytes(byteInput), new Uint8Array([1, 2]), 'byte calls recover after original JS exceptions');

// GC before measurements separates retained host objects from temporary copies.
// Wasm allocation may retain its high-water mark, so warm up with the same work.
async function memoryAfterGC() {
  // ArrayBuffer backing stores can still be swept concurrently after GC returns.
  // A second GC finishes the previous sweep; use the same yields for each sample.
  global.gc();
  await immediate();
  global.gc();
  await immediate();
  return process.memoryUsage();
}
function batch() {
  const data = new Uint8Array(4096);
  for (let i = 0; i < 10000; i++) {
    data[0] = i & 255;
    const output = api.identityBytes(data);
    assert.equal(output[0], data[0]);
  }
}
batch();
const before = await memoryAfterGC();
batch();
const after = await memoryAfterGC();
const retained = {
  heapUsed: after.heapUsed - before.heapUsed,
  arrayBuffers: after.arrayBuffers - before.arrayBuffers,
};
assert.ok(retained.heapUsed < 16 * 1024 * 1024, `host heap grew after warmup: ${retained.heapUsed}`);
assert.ok(retained.arrayBuffers < 16 * 1024 * 1024, `array buffers grew after warmup: ${retained.arrayBuffers}`);
console.log(JSON.stringify({ checks, nativeFunctions: publicNames.length, retained }));
