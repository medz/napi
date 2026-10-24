const assert = require('node:assert/strict');

async function main() {
  const first = process.argv[2] === 'esm-first'
    ? await import('@napi/path')
    : require('@napi/path');
  const counter = new first.Counter(5);
  const reference = new first.RefBox(7);
  first.holdReference(reference);
  first.Counter.count = 11;

  const cjs = require('@napi/path');
  const native = require('@napi/path/native');
  const esm = await import('@napi/path');
  const esmNative = await import('@napi/path/native');
  for (const api of [cjs, native, esm, esmNative]) {
    assert.equal(api.Counter, first.Counter);
    assert.equal(api.RefBox, first.RefBox);
    assert.equal(api.Counter.count, 11);
    assert.equal(api.heldReference(), reference);
    assert.equal(api.identityReference(reference), reference);
    assert.equal(counter instanceof api.Counter, true);
  }
  assert.equal(cjs.Counter.prototype.increment.call(counter, 3), 8);
  assert.equal(esm.Counter.prototype.increment.call(counter), 9);
  assert.equal(native.heldReference().value, 7);
  cjs.heldReference().value = 13;
  assert.equal(esm.heldReference().value, 13);
  assert.equal(cjs.executable(), process.execPath);
  assert.throws(() => new cjs.Counter('5'), TypeError);
  assert.throws(() => counter.increment('1'), TypeError);
}

main().catch(error => { console.error(error); process.exitCode = 1; });
