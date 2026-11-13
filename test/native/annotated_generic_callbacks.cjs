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
  const box = addon.boxedIdentity();
  assert(box instanceof addon.Box);
  assert.equal(box.value(7), 7);
  assert.equal(box.value('hello'), 'hello');
  assert.deepEqual(addon.exerciseBox(box), [true, true]);
  const identity = value => value;
  box.value = identity;
  assert.equal(box.value, identity);
  assert.deepEqual(addon.exerciseBox(box), [true, true]);
  addon.replace(box, identity);
  assert.equal(box.value, identity);
  assert.throws(() => { box.value = 1; }, TypeError);
  box.value = () => 'wrong';
  assert.throws(() => addon.exerciseBox(box), TypeError);
  const listBox = addon.boxedLists();
  assert.deepEqual(listBox.value([1, 2]), [1, 2]);
  listBox.value = values => [...values];
  assert.deepEqual(addon.exerciseListBox(listBox), [true, true]);
  addon.replace(listBox, values => [...values]);
  assert.deepEqual(addon.exerciseListBox(listBox), [true, true]);
  listBox.value = () => ({});
  assert.throws(() => addon.exerciseListBox(listBox), TypeError);
  assert.deepEqual(addon.boxedCallback(box => box), [true, true]);
  assert.throws(() => addon.boxedCallback(box => new addon.Box(box.value)), TypeError);
  const savedBoxes = {};
  assert.deepEqual(await addon.boxedTypes((name, box) => {
    savedBoxes[name] = box;
    switch (name) {
      case 'list':
        assert.deepEqual(box.value, [7]);
        assert.throws(() => { box.value = [1.5]; }, RangeError);
        box.value = [3, 4];
        break;
      case 'int':
        assert.equal(box.value, 9);
        assert.throws(() => { box.value = 1.5; }, RangeError);
        box.value = 10;
        break;
      case 'nested':
        assert.deepEqual(box.value, [[1, null]]);
        box.value = [[2, null]];
        break;
      case 'map': box.value = { value: 2 }; break;
      case 'set':
        assert.deepEqual(box.value, new Set(['one']));
        box.value = new Set(['two']);
        break;
      case 'nullable':
        assert.equal(box.value, null);
        box.value = [2];
        break;
      case 'record':
        assert.deepEqual(box.value, { $1: 1, name: 'one' });
        box.value = { $1: 2, name: 'two' };
        break;
      case 'function':
        assert.equal(box.value(1), '1');
        box.value = value => `value:${value}`;
        break;
      case 'generic':
        assert.equal(box.value(1), 1);
        box.value = value => value;
        break;
      case 'boundFunction':
        box.value = value => {
          assert(value instanceof addon.Box);
          assert.deepEqual(value.value, { items: [1] });
          value.value = { items: [2] };
          return value;
        };
        break;
      case 'point':
        assert.deepEqual(box.value, { value: 1 });
        box.value = { value: '2' };
        break;
      case 'future': box.value = Promise.resolve(2); break;
      case 'stream': box.value = (async function* () { yield 2; })(); break;
      default: assert.fail(name);
    }
  }), Array(13).fill(true));
  // A specialization first reached through a callback must agree with nested returns.
  assert.deepEqual(savedBoxes.int.nested().value, [10]);
  assert.deepEqual(savedBoxes.list.nested().value, [[3, 4]]);
  assert.equal(addon.replaceNested(savedBoxes.list, 12), 'int');
  assert.deepEqual(savedBoxes.list.value, [12]);
  assert.throws(() => addon.replaceNested(savedBoxes.list, 1.5), RangeError);
  assert.equal(savedBoxes.int.append(savedBoxes.list, 13), 'int');
  assert.deepEqual(savedBoxes.list.value, [12, 13]);
  const firstPair = addon.firstPair();
  const secondPair = addon.secondPair();
  assert.equal(addon.replacePairs(firstPair, secondPair, 2, 'two'), 'int/String');
  assert.deepEqual(firstPair.value, [2, 'two']);
  assert.deepEqual(secondPair.value, ['two', 2]);
  const repeatedPair = addon.repeatedPair();
  assert.equal(addon.replaceRepeated(repeatedPair, 3), 'int');
  assert.deepEqual(repeatedPair.value, [3, 3]);
  assert.deepEqual(addon.structuredBox(value => {
    assert.deepEqual(value.box.value, [1]);
    value.box.value = [2];
  }), [2]);
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
