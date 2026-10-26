'use strict';

const assert = require('node:assert/strict');

async function main() {
  const cjs = require('@fixture/counter');
  const esm = await import('@fixture/counter');
  assert.equal(esm.default, cjs);
  assert.equal(esm.Counter, cjs.Counter);
  const a = new cjs.Counter(5);
  const b = new esm.Counter();
  assert(a instanceof esm.Counter);
  assert(b instanceof cjs.Counter);
  assert.equal(a.same(), a);
  assert.equal(esm.Counter.prototype.increment.call(a, 2), 7);
  assert.equal(cjs.Counter.prototype.increment.call(b), 1);
  assert.equal(a.value, 7);
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
