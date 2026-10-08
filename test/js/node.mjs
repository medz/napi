import assert from 'node:assert/strict';
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
  'incrementCounter', 'counter',
];
for (const name of publicNames) {
  assert.equal(typeof api[name], 'function', `${name} is a named function export`);
  assert.equal(api[name], relative[name], `${name} resolves to the same Wasm instance`);
  assert.equal(api[name], subpath[name], `${name} subpath resolves to the same Wasm instance`);
  assert.match(Function.prototype.toString.call(api[name]), /\[native code\]/,
    `${name} is a raw Wasm function`);
}
const checks = runAssertions(api);
assert.equal(relative.identityInt(42), 42);
assert.equal(relative.identityString('relative 你好'), 'relative 你好');
assert.deepEqual(relative.identityBytes(new Uint8Array([1, 128, 255])), new Uint8Array([1, 128, 255]));
assert.deepEqual(api.identityBytes(Buffer.from([1, 128, 255])), new Uint8Array([1, 128, 255]));
assert.deepEqual(api.identityBytes(runInNewContext('new Uint8Array([5, 128, 255])')), new Uint8Array([5, 128, 255]));

// GC before measurements separates retained host objects from temporary copies.
// Wasm allocation may retain its high-water mark, so warm up with the same work.
function batch() {
  const data = new Uint8Array(4096);
  for (let i = 0; i < 10000; i++) {
    data[0] = i & 255;
    const output = api.identityBytes(data);
    assert.equal(output[0], data[0]);
  }
}
batch();
global.gc();
const before = process.memoryUsage();
batch();
global.gc();
const after = process.memoryUsage();
const retained = {
  heapUsed: after.heapUsed - before.heapUsed,
  arrayBuffers: after.arrayBuffers - before.arrayBuffers,
};
assert.ok(retained.heapUsed < 16 * 1024 * 1024, `host heap grew after warmup: ${retained.heapUsed}`);
assert.ok(retained.arrayBuffers < 16 * 1024 * 1024, `array buffers grew after warmup: ${retained.arrayBuffers}`);
console.log(JSON.stringify({ checks, nativeFunctions: publicNames.length, retained }));
