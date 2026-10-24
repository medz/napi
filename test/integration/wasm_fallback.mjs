import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {readFile, writeFile, unlink} from 'node:fs/promises';

const require = createRequire(import.meta.url);
const name = '@napi/fallback-fixture';
const mode = process.argv[2];
if (mode === 'unsupported') {
  Object.defineProperty(process, 'arch', {value: 'unsupported'});
  const api = await import(name);
  const wasm = await import(name + '/wasm');
  assert.equal(api.Counter, wasm.Counter);
  assert.equal(api.singleton(), wasm.singleton());
  assert.equal(new api.Counter(2).increment(), 3);
  assert.equal(api.add(3), 5);
  assert.equal(wasm.calls(), 1);
  assert.throws(() => require(name), /requires/);
  await assert.rejects(import(name + '/native'), /requires/);
} else if (mode === 'missing' || mode === 'broken') {
  const module = import.meta.resolve(name + '/native');
  const file = mode === 'missing' ? new URL('./bridge.node', module) : new URL(module);
  const original = await readFile(file);
  const failure = globalThis.nativeFailure = new Error('native startup failed');
  try {
    if (mode === 'missing') await unlink(file);
    else await writeFile(file, 'throw globalThis.nativeFailure;');
    let error;
    try { await import(name); } catch (value) { error = value; }
    assert(error instanceof Error);
    if (mode === 'missing') assert.equal(error.code, 'MODULE_NOT_FOUND');
    else assert.equal(error, failure);
    await assert.rejects(import(name + '/native'), value => value === error);
  } finally {
    await writeFile(file, original);
  }
} else {
  const first = mode === 'cjs-first' ? require(name) : await import(name);
  const api = await import(name);
  const common = require(name);
  const native = await import(name + '/native');
  assert.equal(first.Counter, api.Counter);
  assert.equal(common.Counter, api.Counter);
  assert.equal(native.Counter, api.Counter);
  assert.equal(api.singleton(), common.singleton());
  assert.equal(api.singleton(), native.singleton());
  assert.equal(api.add(3), 5);
  assert.equal(common.calls(), 1);
  assert.equal(native.calls(), 1);
  assert.equal(new api.Counter(2).increment(), 3);
  const wasm = await import(name + '/wasm');
  assert.notEqual(wasm.Counter, api.Counter);
  assert.notEqual(wasm.singleton(), api.singleton());
  assert.equal(wasm.calls(), 0);
  assert.equal(wasm.add(5), 7);
  assert.equal(api.calls(), 1);
  assert.throws(() => api.Counter.prototype.increment.call(wasm.singleton()), TypeError);
}
