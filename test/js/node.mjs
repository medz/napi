import assert from 'node:assert/strict';
import { runInNewContext } from 'node:vm';
import * as api from '@napi/integration';
import { runAssertions } from './assertions.mjs';

const checks = runAssertions(api);
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
console.log(JSON.stringify({ checks, retained }));
