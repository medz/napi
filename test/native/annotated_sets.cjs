'use strict';

const assert = require('node:assert/strict');

function input(value, close) {
  let index = 0;
  const iterator = {
    next() {
      assert.equal(this, iterator);
      return index++ === 0 ? { done: false, get value() { return value(); } } : { done: true };
    },
    return() { assert.equal(this, iterator); return close(); },
  };
  const source = { values() { assert.equal(this, source); return iterator; } };
  return source;
}

module.exports = function verifyAnnotatedSets(path) {
  const addon = require(path);
  const values = new Set([3, 1, 2]);
  const copied = addon.echoInts(values);
  assert(copied instanceof Set);
  assert.notEqual(copied, values);
  assert.deepEqual([...copied], [3, 1, 2]);
  values.add(5);
  copied.add(4);
  assert.deepEqual([...addon.lastInts()], [3, 1, 2]);
  assert.deepEqual([...values], [3, 1, 2, 5]);
  const nested = [new Set([1, null]), null];
  const nestedCopy = addon.echoNested(nested);
  assert.notEqual(nestedCopy, nested);
  assert.notEqual(nestedCopy[0], nested[0]);
  assert.deepEqual([...nestedCopy[0]], [1, null]);
  assert.equal(nestedCopy[1], null);
  assert.throws(() => addon.echoNested([new Set([undefined])]), TypeError);
  assert.throws(() => addon.echoInts({}), TypeError);

  const instant = 1700000000123;
  const dates = addon.echoDates(new Set([new Date(instant), new Date(instant)]));
  assert.equal(dates.size, 1);
  assert.equal([...dates][0].getTime(), instant);
  const numbers = [...addon.specialNumbers()];
  assert.equal(numbers.length, 2);
  assert(Object.is(numbers[0], 0));
  assert(Number.isNaN(numbers[1]));
  const key = new addon.Key(7);
  assert.equal([...addon.echoKeys(new Set([key]))][0], key);
  const object = {};
  assert.equal([...addon.echoObjects(new Set([object]))][0], object);

  let callbackInput;
  const result = addon.bounceSet(value => { callbackInput = value; return value; })(new Set([2, 1]));
  assert.notEqual(result, callbackInput);
  assert.deepEqual([...result], [2, 1]);
  assert.deepEqual([...addon.echoInts(input(() => 7, () => { throw new Error('Unexpected close'); }))], [7]);

  const reason = {};
  let closed = 0;
  assert.throws(() => addon.echoInts(input(
    () => { throw reason; }, () => { closed++; return {}; },
  )), error => error === reason);
  assert.equal(closed, 0, 'Reading iterator.value must not close the iterator');
  assert.throws(() => addon.echoInts(input(
    () => 'wrong', () => { closed++; throw new Error('secondary close failure'); },
  )), TypeError);
  assert.equal(closed, 1);
  const brokenKey = new addon.Key(9, reason);
  closed = 0;
  assert.throws(() => addon.echoKeys(input(
    () => brokenKey, () => { closed++; throw new Error('secondary close failure'); },
  )), error => error === reason);
  assert.equal(closed, 1, 'Set.add failure must close once and retain its original error');
};
