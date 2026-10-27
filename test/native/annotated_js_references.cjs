'use strict';

const assert = require('node:assert/strict');
const nextTurn = () => new Promise(resolve => setImmediate(resolve));

module.exports = async function verifyAnnotatedJsReferences(path) {
  const addon = require(path);
  let reads = 0;
  const proxy = new Proxy({}, {
    get() { reads++; throw new Error('Opaque value was inspected'); },
    ownKeys() { reads++; throw new Error('Opaque value was enumerated'); },
    getOwnPropertyDescriptor() { reads++; throw new Error('Opaque value was inspected'); },
  });
  const object = { get value() { reads++; throw new Error('Object getter was read'); } };
  const array = [1, { nested: true }];
  const callback = value => value;
  const symbol = Symbol('owned');
  for (const value of [object, array, proxy, callback, symbol]) {
    assert.equal(addon.echoValue(value), value);
    assert.equal(addon.echoNonNull(value), value);
    assert.equal(addon.echoDynamic(value), value);
    addon.saveValue(value);
    assert.equal(addon.savedValue(), value);
    assert.equal(addon.savedValue(), value, 'Returning a reference consumed it');
    if (value !== proxy) assert.equal(await addon.savedLater(), value);
    assert.equal(addon.savedValue(), value);
    addon.clearValue();
    assert.equal(addon.savedValue(), null);
  }
  assert.equal(reads, 0);
  addon.clearValue();
  assert.equal(addon.echoObject(object), object);
  assert.equal(addon.echoObject(array), array);
  assert.equal(addon.echoObject(proxy), proxy);
  assert.equal(addon.echoObject(callback), callback);
  assert.equal(addon.echoFunction(callback), callback);
  assert.equal(addon.echoSymbol(symbol), symbol);
  assert.equal(addon.optionalObject(), null);
  assert.equal(addon.optionalObject(null), null);
  assert.equal(addon.optionalObject(object), object);
  for (const invalid of [null, undefined, 1, 'text', symbol]) {
    assert.throws(() => addon.echoObject(invalid), TypeError);
  }
  for (const invalid of [{}, null, undefined, symbol]) {
    assert.throws(() => addon.echoFunction(invalid), TypeError);
  }
  for (const invalid of [{}, callback, null, undefined, 'owned']) {
    assert.throws(() => addon.echoSymbol(invalid), TypeError);
  }
  assert.throws(() => addon.optionalObject(undefined), TypeError);
  assert.throws(() => addon.disposedObject(object), /disposed/);
  assert.equal(addon.echoObject(object), object);

  for (const value of [null, undefined, true, 7, 1.5, NaN, -0, '中文\ud800', 1n << 100n]) {
    assert(Object.is(addon.echoValue(value), value));
    assert(Object.is(addon.echoDynamic(value), value));
    if (value !== null) assert(Object.is(addon.echoNonNull(value), value));
  }
  assert.throws(() => addon.echoNonNull(null), TypeError);
  assert.equal(addon.echoUndefined(undefined), undefined);
  assert.equal(addon.optionalUndefined(), null);
  assert.equal(addon.optionalUndefined(null), null);
  assert.equal(addon.optionalUndefined(undefined), undefined);
  for (const invalid of [null, 1, {}]) {
    assert.throws(() => addon.echoUndefined(invalid), TypeError);
  }
  assert.equal(addon.presence(), 'missing');
  assert.equal(addon.presence(undefined), 'undefined');
  assert.equal(addon.presence(null), 'null');
  assert.equal(addon.presence(object), 'value');
  const inputs = [object, array, callback, symbol, null, undefined];
  const copied = addon.echoValues(inputs);
  assert.notEqual(copied, inputs);
  for (let index = 0; index < inputs.length; index++) assert.equal(copied[index], inputs[index]);
  assert.deepEqual(addon.echoSymbols([symbol]), [symbol]);
  assert.throws(() => addon.echoSymbols([symbol, object]), TypeError);
  assert.equal(addon.applyValue(object, value => { assert.equal(value, object); return array; }), array);
  const stream = [];
  for await (const value of addon.symbolStream(symbol)) stream.push(value);
  assert.deepEqual(stream, [symbol]);
  for (const invalidOutput of [addon.dartList, addon.dartRecord, addon.dartClass]) {
    assert.throws(invalidOutput, TypeError);
  }
  assert.equal(reads, 0);

  async function saveUnreachable() {
    const value = {};
    addon.saveValue(value);
    return new WeakRef(value);
  }
  const retained = await saveUnreachable();
  await nextTurn();
  global.gc();
  assert.notEqual(retained.deref(), undefined);
  addon.clearValue();
  for (let round = 0; round < 32; round++) {
    await nextTurn();
    global.gc();
    if (retained.deref() === undefined) break;
  }
  assert.equal(retained.deref(), undefined, 'Disposed saved value remained retained');
};
