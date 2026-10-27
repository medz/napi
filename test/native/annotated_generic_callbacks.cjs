'use strict';

const assert = require('node:assert/strict');
const { setImmediate: nextTurn } = require('node:timers/promises');
const { Worker } = require('node:worker_threads');

function worker(path) {
  return new Promise((resolve, reject) => {
    let message;
    const child = new Worker(`
      const { parentPort, workerData } = require('node:worker_threads');
      const addon = require(workerData);
      let saved;
      addon.capture(value => { saved = value; return value; });
      addon.readCaptured(() => saved).then(value => parentPort.postMessage(value));
    `, { eval: true, workerData: path });
    const timeout = setTimeout(() => {
      child.terminate();
      reject(new Error('Generic callback worker did not exit'));
    }, 10000);
    child.on('error', reject);
    child.on('message', value => { message = value; });
    child.on('exit', code => {
      clearTimeout(timeout);
      try {
        assert.equal(code, 0);
        assert.equal(message, 17);
        resolve();
      } catch (error) { reject(error); }
    });
  });
}

module.exports = async function verifyAnnotatedGenericCallbacks(path) {
  const addon = require(path);
  const seen = [];
  const result = addon.exercise(value => { seen.push(value); return value; });
  assert.deepEqual(Object.values(result), Array(14).fill(true));
  assert.equal(seen.length, 14);
  assert.deepEqual(seen.slice(0, 5), [7, 3, '\ud800中', null, 1n << 65n]);
  for (const native of seen.slice(5)) {
    assert.equal(typeof native, 'object');
    assert.equal(Array.isArray(native), false);
    assert.equal(native instanceof Date, false);
  }
  let listCalls = 0;
  assert.deepEqual(addon.explicitLists(values => {
    assert(Array.isArray(values));
    if (listCalls++ === 0) assert.deepEqual(values, [1, 2]);
    else assert.equal(Array.isArray(values[0]), false);
    return [...values];
  }), [true, true]);
  assert.equal(listCalls, 2);
  assert.throws(() => addon.explicitLists(() => ({})), TypeError);

  const id = addon.identity();
  for (const value of [7, 'hello', {}, [], new Date(), value => value, Symbol('origin'), null, undefined]) {
    assert.equal(id(value), value);
    assert.equal(addon.origin(value, item => item), value);
  }
  const proxy = new Proxy({}, { get() { throw new Error('Opaque property read'); } });
  assert.equal(addon.origin(proxy, value => value), proxy);
  assert.equal(addon.shadow(7, value => value), 7);
  assert.equal(addon.nested(callback => callback), 7);
  assert.equal(addon.independent((first, second) => {
    assert.equal(first, second);
    return first;
  }, value => value), true);
  assert.deepEqual(addon.numeric(value => value), [true, true]);
  assert.throws(() => addon.numeric(() => 'wrong'), TypeError);
  assert.throws(() => addon.numeric(() => 1.5), RangeError);
  assert.equal(addon.numericIdentity()(1.5), 1.5);
  assert.throws(() => addon.numericIdentity()('wrong'), TypeError);
  const nonNull = addon.nonNullIdentity();
  const object = {};
  assert.equal(nonNull(object), object);
  assert.throws(() => nonNull(null), TypeError);
  assert.equal(new addon.Forward(1.5).value, 1.5);
  assert.throws(() => new addon.Forward('wrong'), TypeError);
  assert.deepEqual(addon.borrowed(value => value), [true, true, true]);
  const calls = [];
  assert.deepEqual(addon.optionalCalls(function (value, options) {
    calls.push([...arguments]);
    return options ? options.fallback : value;
  }), [1, 9]);
  assert.deepEqual(calls, [[1], [2, { fallback: 9 }]]);
  const fallback = addon.fallbackIdentity();
  assert.equal(fallback(1), 1);
  assert.equal(fallback(1, { fallback: 9 }), 9);
  assert.equal(fallback(1, { fallback: null }), 1);

  const counter = new addon.Counter(9);
  let counterHandle;
  assert.equal(addon.counterRoundtrip(counter, value => { counterHandle = value; return value; }), true);
  assert.notEqual(counterHandle, counter);
  assert(counter instanceof addon.Counter);
  assert.throws(() => addon.counterRoundtrip(counter, () => counter), TypeError);
  assert.throws(() => addon.capture(() => ({})), TypeError);
  assert.throws(() => addon.capture(() => seen[5]), TypeError);
  const reason = {};
  assert.throws(() => addon.exercise(() => { throw reason; }), error => error === reason);

  let saved;
  assert.equal(addon.capture(value => { saved = value; return value; }), true);
  assert.equal(await addon.asyncNative(async ({ value }) => {
    await nextTurn();
    return value;
  }), true);
  assert.equal(await addon.asyncOrigin(seen[9], async ({ value }) => {
    await nextTurn();
    return value;
  }), seen[9]);
  const weak = new WeakRef(saved);
  await nextTurn();
  global.gc();
  assert.equal(await addon.readCaptured(() => saved), 17);
  assert.equal(await addon.readCaptured(() => saved), 17);
  saved = null;
  for (let i = 0; i < 32; i++) {
    await nextTurn();
    global.gc();
    await nextTurn();
    if (weak.deref() === undefined) break;
  }
  assert.equal(weak.deref(), undefined, 'A released opaque value retained its JS handle');
  let originHandle;
  assert.equal(addon.capture(value => { originHandle = value; return value; }), true);
  assert.equal(addon.borrowedOrigin(originHandle, id), originHandle);
  for (const opaque of [originHandle, seen[9]]) {
    assert.equal(addon.origin(opaque, value => value), opaque);
    assert.equal(id(opaque), opaque);
  }
  await worker(path);
};
