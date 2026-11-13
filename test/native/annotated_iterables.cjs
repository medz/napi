'use strict';

const assert = require('node:assert/strict');

module.exports = async function verify(path) {
  const addon = require(path);
  const values = addon.sequence();
  const unused = values[Symbol.iterator]();
  unused.return();
  assert.deepEqual(addon.events(), []);
  assert.deepEqual([...values], [0, 1, 2]);
  assert.deepEqual([...values], [0, 1, 2]);
  assert.deepEqual(addon.events(), ['start', 'close', 'start', 'close']);
  const left = values[Symbol.iterator](), right = values[Symbol.iterator]();
  assert.equal(left[Symbol.iterator](), left);
  assert.equal(left.next().value, 0);
  assert.equal(right.next().value, 0);
  assert.equal(left.next().value, 1);
  assert.deepEqual(left.return('done'), { done: true, value: 'done' });
  left.return();
  assert.deepEqual(left.next(), { done: true, value: undefined });
  right.return();
  assert.deepEqual(addon.events(), ['start', 'start', 'close', 'close']);
  for (const value of addon.nested()) {
    assert.equal(value, 0);
    break;
  }
  assert.deepEqual(addon.events(), ['start', 'close', 'outer', 'finished']);
  assert.throws(() => [...addon.unsafe()], RangeError);
  assert.deepEqual(addon.events(), ['unsafe:close']);

  let closed = 0;
  function* source() {
    try { yield 0; yield 1; yield 2; } finally { ++closed; }
  }
  assert.equal(addon.first(source()), 0);
  assert.equal(addon.stop(source()), -1);
  assert.equal(addon.stop([7, 8]), 7);
  assert.deepEqual(addon.take(source(), 1), [0]);
  assert.equal(closed, 3);
  for (const value of addon.delegate(source())) {
    assert.equal(value, 0);
    break;
  }
  assert.equal(closed, 4);
  assert.deepEqual(addon.events(), ['delegate:close']);
  assert.equal(await addon.delayedFirst(source()), 0);
  assert.equal(closed, 5);
  assert.deepEqual(addon.strings('A😀'), ['A', '😀']);
  assert.deepEqual(addon.strings(new Set(['a', 'b'])), ['a', 'b']);
  assert.deepEqual([...addon.points([{ x: 2 }])], [{ x: 3 }]);
  assert.deepEqual([...addon.amounts([{ value: '2' }])], [{ value: 2 }]);
  assert.deepEqual([...addon.boxed(box => {
    assert.deepEqual([...box.value], [{ value: 3 }]);
    box.value = [{ value: '4' }];
  })], [{ value: 4 }]);
  assert.equal(addon.nullable(), null);
  assert.equal(addon.nullable(null), null);
  assert.deepEqual([...addon.nullable([1])], [1]);
  const object = { raw: true };
  assert.equal([...addon.echo([object])][0], object);
  addon.save([4, 5]);
  if (global.gc) global.gc();
  assert.equal(addon.savedFirst(), 4);
  addon.clear();
  assert.deepEqual([...addon.callback(function* (items) {
    for (const value of items) yield value + 1;
  })], [1, 2, 3]);
  assert.deepEqual([...await addon.later()], [0, 1, 2]);
  addon.events();

  const bodyError = /body failed/;
  let returned = 0;
  const cleanupError = new Error('cleanup failed');
  const malformed = value => ({
    [Symbol.iterator]() {
      return {
        next() { return { value, done: false }; },
        return() { ++returned; throw cleanupError; },
      };
    },
  });
  assert.throws(() => addon.first(malformed(1)), error => error === cleanupError);
  assert.throws(() => addon.fail(malformed(1)), bodyError);
  assert.throws(() => addon.first(malformed(1.5)), RangeError);
  assert.equal(returned, 3);
  assert.throws(() => addon.first({}), TypeError);
  assert.throws(() => addon.first(null), TypeError);
  assert.throws(() => addon.first({ [Symbol.iterator]: () => 1 }), TypeError);
  assert.throws(() => addon.first({ [Symbol.iterator]: () => ({ next: () => 1 }) }), TypeError);
  assert.throws(() => addon.first({
    [Symbol.iterator]: () => ({ next: () => ({ value: 1 }), return: () => 1 }),
  }), TypeError);
  let reentrant;
  reentrant = addon.reentrant(() => reentrant.next())[Symbol.iterator]();
  assert.throws(() => reentrant.next(), /already running/);
  assert.deepEqual(addon.events(), ['reentrant:close']);
};
