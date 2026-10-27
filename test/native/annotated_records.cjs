'use strict';

const assert = require('node:assert/strict');

module.exports = async function verifyAnnotatedRecords(path) {
  const addon = require(path);
  const pair = [7, 'Dart 中文\ud800'];
  const copied = addon.echoPair(pair);
  assert.deepEqual(copied, pair);
  assert.notEqual(copied, pair);
  const named = { text: '你好\udfff', value: (1n << 100n) + 7n, maybe: null };
  const copiedNamed = addon.echoNamed(named);
  assert.deepEqual(copiedNamed, named);
  assert.notEqual(copiedNamed, named);
  const mixed = { $1: 3, $2: 5, length: 7 };
  assert.deepEqual(addon.echoMixed(mixed), mixed);
  assert.deepEqual(addon.echoEmpty([]), []);
  assert.equal(addon.nullablePair(), null);
  assert.equal(addon.nullablePair(null), null);
  assert.deepEqual(addon.nullablePair([null, null]), [null, null]);
  assert.deepEqual(addon.defaultPair(), [3, 'private']);
  assert.deepEqual(addon.defaultPair([9, 'explicit']), [9, 'explicit']);
  assert.deepEqual(addon.defaultNamed(), { enabled: true, label: 'default' });
  assert.deepEqual(addon.defaultNamed({}), { enabled: true, label: 'default' });
  assert.deepEqual(addon.defaultNamed({ value: { enabled: false, label: 'explicit' } }),
    { enabled: false, label: 'explicit' });

  const box = new addon.RecordBox(11);
  const boxed = { item: box, point: [1, 2] };
  const boxedCopy = addon.echoBoxed(boxed);
  assert.notEqual(boxedCopy, boxed);
  assert.notEqual(boxedCopy.point, boxed.point);
  assert.equal(boxedCopy.item, box);
  const holder = new addon.RecordHolder(pair);
  pair[0] = 99;
  assert.deepEqual(holder.value, [7, 'Dart 中文\ud800']);
  const read = holder.value;
  read[0] = 100;
  assert.equal(holder.value[0], 7);
  assert.deepEqual(holder.replace([2, 'next']), [7, 'Dart 中文\ud800']);
  assert.deepEqual(holder.value, [2, 'next']);
  holder.value = [4, 'setter'];
  assert.deepEqual(holder.value, [4, 'setter']);
  assert.deepEqual(addon.transformPair([3, 5], ([a, b]) => [a + 1, b + 1]), [4, 6]);
  assert.deepEqual(addon.pairSwapper()([3, 5]), [5, 3]);
  assert.throws(() => addon.transformPair([3, 5], () => [1]), TypeError);
  const rows = [{ number: 7, label: null }];
  const rowsCopy = addon.echoRows(rows);
  assert.deepEqual(rowsCopy, rows);
  assert.notEqual(rowsCopy, rows);
  assert.notEqual(rowsCopy[0], rows[0]);
  assert.deepEqual(await addon.futurePair(Promise.resolve([3, 'async'])), [3, 'async']);
  const streamed = [];
  for await (const value of addon.pairStream([5, 'stream'])) streamed.push(value);
  assert.deepEqual(streamed, [[5, 'stream']]);
  assert.deepEqual(await addon.collectPairs((async function* () {
    yield [7, 'input'];
  })()), [[7, 'input']]);

  for (const invalid of [[], [1], [1, 'x', 3], { 0: 1, 1: 'x', length: 2 }, null]) {
    assert.throws(() => addon.echoPair(invalid), TypeError);
  }
  assert.throws(() => addon.echoEmpty([1]), TypeError);
  assert.throws(() => addon.echoEmpty({}), TypeError);
  assert.throws(() => addon.nullablePair(undefined), TypeError);
  assert.throws(() => addon.nullablePair([null, undefined]), TypeError);
  assert.throws(() => addon.defaultPair(undefined), TypeError);
  assert.throws(() => addon.defaultNamed({ value: undefined }), TypeError);
  assert.throws(() => addon.echoNamed({ text: 'x', value: 1n }), TypeError);
  assert.throws(() => addon.echoNamed({ text: 'x', value: 1n, maybe: undefined }), TypeError);
  assert.throws(() => addon.echoMixed({ $1: 3, $2: 5 }), TypeError);
  assert.throws(() => addon.echoMixed([3, 5, 7]), TypeError);
  assert.throws(() => addon.echoNamed(Object.create(named)), TypeError);
  const sparse = [1, 'x'];
  delete sparse[1];
  Object.setPrototypeOf(sparse, { 1: 'inherited' });
  assert.throws(() => addon.echoPair(sparse), TypeError);

  let textReads = 0, valueReads = 0, maybeReads = 0;
  assert.deepEqual(addon.echoNamed({
    get text() { textReads++; return 'once'; },
    get value() { valueReads++; return 1n; },
    get maybe() { maybeReads++; return null; },
    get ignored() { throw new Error('Extra record field was read'); },
  }), { text: 'once', value: 1n, maybe: null });
  assert.deepEqual([textReads, valueReads, maybeReads], [1, 1, 1]);
  const reason = {};
  assert.throws(() => addon.echoNamed({
    get text() { throw reason; }, value: 1n, maybe: null,
  }), error => error === reason);
  const throwingPair = [1, 'x'];
  Object.defineProperty(throwingPair, '0', { get() { throw reason; } });
  assert.throws(() => addon.echoPair(throwingPair), error => error === reason);
  let inheritedReads = 0;
  const mutating = Object.create({ get value() { inheritedReads++; return 9n; } });
  Object.defineProperties(mutating, {
    text: { enumerable: true, get() { delete this.value; return 'deleted'; } },
    value: { enumerable: true, configurable: true, value: 3n },
    maybe: { enumerable: true, value: null },
  });
  assert.throws(() => addon.echoNamed(mutating), TypeError);
  assert.equal(inheritedReads, 0);

  const descriptor = Object.getOwnPropertyDescriptor(Object.prototype, '$1');
  let setterCalls = 0;
  let safeMixed;
  try {
    Object.defineProperty(Object.prototype, '$1', {
      configurable: true, set() { setterCalls++; },
    });
    safeMixed = addon.echoMixed(mixed);
  } finally {
    if (descriptor) Object.defineProperty(Object.prototype, '$1', descriptor);
    else delete Object.prototype.$1;
  }
  assert.equal(setterCalls, 0);
  assert.equal(Object.hasOwn(safeMixed, '$1'), true);
  assert.deepEqual(safeMixed, mixed);
};
