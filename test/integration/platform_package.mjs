import assert from 'node:assert/strict';
import {Worker, isMainThread} from 'node:worker_threads';
import * as root from '@napi/platform-fixture';
import * as native from '@napi/platform-fixture/native';
import * as wasm from '@napi/platform-fixture/wasm';

assert.equal(root.Counter, native.Counter);
assert.equal(root.add, native.add);
assert.equal(root.singleton(), native.singleton());
assert.equal(root.calls(), 0);
assert.equal(root.add(3), 5);
assert.equal(native.calls(), 1);
assert.equal(new root.Counter().increment(), 2);
assert.equal(new native.Counter(10).increment(3), 13);
assert.equal(root.singleton().increment(), 8);
assert.equal(native.singleton().value, 8);

assert.notEqual(root.Counter, wasm.Counter);
assert.equal(wasm.calls(), 0);
assert.equal(wasm.add(4), 6);
assert.equal(wasm.calls(), 1);
assert.equal(wasm.singleton().value, 7);
assert.equal(new wasm.Counter(10).increment(3), 13);

if (isMainThread) {
  await new Promise((resolve, reject) => {
    const worker = new Worker(new URL(import.meta.url));
    worker.on('error', reject);
    worker.on('exit', code => code === 0 ? resolve() : reject(Error(`Worker exited ${code}`)));
  });
  assert.equal(native.calls(), 1);
  assert.equal(native.singleton().value, 8);
}
