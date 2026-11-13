'use strict';

const assert = require('node:assert/strict');

module.exports = async function verifyFutureOr(path) {
  const addon = require(path);
  assert.equal(addon.echo(3), 3);
  const pending = addon.echo(Promise.resolve(4));
  assert(pending instanceof Promise);
  assert.equal(await pending, 4);
  for (const invalid of [undefined, null, '3', {}, { then(resolve) { resolve(3); } }]) {
    assert.throws(() => addon.echo(invalid), TypeError);
  }
  assert.throws(() => addon.echo(1.5), RangeError);
  await assert.rejects(addon.echo(Promise.resolve('3')), TypeError);
  await assert.rejects(addon.echo(Promise.resolve(2 ** 53)), RangeError);
  const reason = {};
  await assert.rejects(addon.echo(Promise.reject(reason)), error => error === reason);
  assert.equal(addon.nullable(null), null);
  assert.equal(await addon.nullable(Promise.resolve(null)), null);
  assert.equal(addon.optional(), null);
  assert.equal(addon.optional(null), null);
  assert.throws(() => addon.optional(undefined), TypeError);
  assert.equal(await addon.nested(Promise.resolve(null)), null);
  assert.equal(await addon.nested(Promise.resolve(5)), 5);
  assert.equal(await addon.futureValue(Promise.resolve(6)), 6);
  assert.equal(await addon.envelope({ value: Promise.resolve(7) }).value, 7);
  assert.equal(addon.ignored(undefined), undefined);
  assert.equal(await addon.ignored(Promise.resolve(3)), undefined);
  const values = addon.values([1, Promise.resolve(2)]);
  assert.equal(values[0], 1);
  assert(values[1] instanceof Promise);
  assert.deepEqual(await Promise.all(values), [1, 2]);
  assert.equal(addon.apply(value => value + 1), 8);
  assert.equal(await addon.apply(async value => value + 2), 9);
  assert.throws(() => addon.apply(() => 'wrong'), TypeError);
  await assert.rejects(addon.apply(async () => 'wrong'), TypeError);
  const callback = addon.callback();
  assert.equal(callback(6), 6);
  assert.equal(await callback(Promise.resolve(7)), 7);
  assert.deepEqual(addon.amount({ value: '42' }), { value: 42 });
  assert.deepEqual(await addon.amount(Promise.resolve({ value: '43' })), { value: 43 });
  assert.throws(() => addon.amount({ value: 42 }), TypeError);
  await assert.rejects(addon.amount(Promise.resolve({ value: 42 })), TypeError);
  assert.deepEqual(addon.amountEnvelope({ value: { value: '44' } }).value, { value: 44 });
  assert.deepEqual(await addon.amountEnvelope({ value: Promise.resolve({ value: '45' }) }).value, { value: 45 });
  const box = addon.box(false);
  assert.equal(box.value, 3);
  box.value = Promise.resolve(8);
  assert.equal(await box.value, 8);
  box.value = 9;
  assert.equal(box.value, 9);
  assert.equal(await addon.box(true).value, 3);
  assert.equal(await addon.generic(value => value), 9);
  assert.equal(await addon.boxed(box => {
    assert(box.value instanceof Promise);
    box.value = Promise.resolve([10]);
  }), 10);
  const sync = addon.thenable(false, true);
  assert.equal(typeof sync.then, 'function');
  assert.equal(await addon.thenable(true, true), 11);
  const noncallable = await addon.thenable(true, false);
  assert(noncallable.then instanceof Promise);
  let resolved;
  (await noncallable.then)(value => { resolved = value; });
  assert.equal(resolved, 11);
  const echoed = await addon.echoThenable(Promise.resolve({ then: Promise.resolve(resolve => resolve(12)) }));
  assert(echoed.then instanceof Promise);
};
