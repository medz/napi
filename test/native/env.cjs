'use strict';

const assert = require('node:assert/strict');
const { dirname, join } = require('node:path');
const { setImmediate: nextTurn } = require('node:timers/promises');
const { Worker } = require('node:worker_threads');

async function collectUntil(predicate, message) {
  for (let i = 0; i < 32; ++i) {
    // A WeakRef dereference keeps its target alive until the current job ends.
    await nextTurn();
    global.gc();
    await nextTurn();
    if (predicate()) return;
  }
  assert.fail(message);
}

function throwsValue(body, value) {
  let caught = false;
  try {
    body();
  } catch (error) {
    caught = true;
    assert.equal(error, value);
  }
  assert(caught, 'JavaScript exception was swallowed');
}

function worker(path, terminate) {
  return new Promise((resolve, reject) => {
    let ready = false;
    const worker = new Worker(`
      const { parentPort, workerData } = require('node:worker_threads');
      const addon = require(workerData.path);
      const counter = new addon.Counter(10);
      addon.saveCallback(value => counter.increment(value));
      if (workerData.terminate) setInterval(() => {}, 1000);
      parentPort.postMessage(addon.callSaved(2));
    `, { eval: true, workerData: { path, terminate } });
    worker.on('message', value => {
      try {
        assert.equal(value, 12);
        assert.equal(ready, false);
        ready = true;
        if (terminate) worker.terminate().catch(reject);
      } catch (error) {
        worker.terminate().catch(() => {});
        reject(error);
      }
    });
    worker.on('error', reject);
    worker.on('exit', code => {
      try {
        assert(ready, 'Worker exited before invoking its retained callback');
        assert.equal(code, terminate ? 1 : 0);
        resolve();
      } catch (error) { reject(error); }
    });
  });
}

module.exports = async function verifyEnv(path) {
  assert.equal(typeof global.gc, 'function', 'Run Node with --expose-gc');
  const addon = require(path);
  const { Counter, Other } = addon;
  const a = new Counter(5);
  const b = new Counter();
  assert(a instanceof Counter);
  assert.notEqual(a, b);
  assert.equal(a.value, 5);
  assert.equal(a.increment(), 6);
  assert.equal(a.increment(2), 8);
  assert.equal(b.increment(-3), -3);
  a.value = 20;
  assert.equal(a.value, 20);
  assert.equal(a.increment(), 21);
  assert.equal(b.value, -3);
  assert.throws(() => Counter(2), TypeError);
  const { get, set } = Object.getOwnPropertyDescriptor(Counter.prototype, 'value');
  assert.equal(get.call(a, 123), 21);
  assert.equal(a.value, 21);
  assert.throws(() => set.call(a), TypeError);
  assert.equal(a.value, 21);
  assert.equal(set.call(a, 25, 99), undefined);
  assert.equal(a.value, 25);
  a.value = 21;
  for (const receiver of [{}, Object.create(Counter.prototype), new Other()]) {
    assert.throws(() => Counter.prototype.increment.call(receiver), TypeError);
    assert.throws(() => get.call(receiver), TypeError);
    assert.throws(() => set.call(receiver, 3), TypeError);
  }

  const wrongIntegers = [undefined, null, true, '1', 1n, {}, []];
  const outsideIntegers = [NaN, Infinity, -Infinity, 1.5, 2 ** 53, -(2 ** 53)];
  for (const [values, ErrorType] of [
    [wrongIntegers, TypeError], [outsideIntegers, RangeError],
  ]) {
    for (const value of values) {
      assert.throws(() => new Counter(value), ErrorType);
      assert.throws(() => a.increment(value), ErrorType);
      assert.throws(() => { a.value = value; }, ErrorType);
      assert.throws(() => addon.echoInt(value), ErrorType);
    }
  }
  assert.equal(a.value, 21);
  for (const value of [0, -1, Number.MIN_SAFE_INTEGER, Number.MAX_SAFE_INTEGER]) {
    assert.equal(addon.echoInt(value), value);
    assert.equal(addon.echoNullableInt(value), value);
    a.value = value;
    assert.equal(a.value, value);
  }
  assert.throws(() => a.increment(), RangeError);
  assert.equal(a.value, Number.MAX_SAFE_INTEGER);
  a.value = Number.MIN_SAFE_INTEGER;
  assert.throws(() => a.increment(-1), RangeError);
  assert.equal(a.value, Number.MIN_SAFE_INTEGER);
  a.value = 21;
  assert.throws(() => addon.returnMinInt(), RangeError);
  assert.equal(addon.echoNullableInt(null), null);
  for (const value of wrongIntegers.filter(value => value !== null)) {
    assert.throws(() => addon.echoNullableInt(value), TypeError);
  }
  for (const value of outsideIntegers) {
    assert.throws(() => addon.echoNullableInt(value), RangeError);
  }

  for (const value of [0, -0, 2, 1.5, NaN, Infinity, -Infinity]) {
    assert.equal(addon.echoDouble(value), value);
    assert.equal(addon.echoNullableDouble(value), value);
  }
  for (const value of [true, false]) assert.equal(addon.echoBool(value), value);
  for (const value of ['', 'Dart 中文 🌍', 'a\0b', '\ud800x\udfff']) {
    assert.equal(addon.echoString(value), value);
  }
  const highLimbs = (1n << 255n) | (1n << 191n) | (1n << 127n) | (1n << 63n) | 123n;
  for (const value of [0n, 1n, -1n, 1n << 63n, -(1n << 63n),
    (1n << 64n) - 1n, -((1n << 64n) - 1n), 1n << 64n, -(1n << 64n),
    (1n << 200n) + 123n, -(1n << 200n) - 123n, highLimbs, -highLimbs]) {
    assert.equal(addon.echoBigInt(value), value);
  }
  assert.equal(addon.echoNullableDouble(null), null);
  for (const [name, wrong] of [
    ['echoDouble', [undefined, null, true, '1', 1n, {}]],
    ['echoNullableDouble', [undefined, true, '1', 1n, {}]],
    ['echoBool', [undefined, null, 0, 1, 'true', {}]],
    ['echoString', [undefined, null, 1, true, 1n, Symbol('text'), {}]],
    ['echoBigInt', [undefined, null, 1, '1', true, {}]],
  ]) {
    for (const value of wrong) assert.throws(() => addon[name](value), TypeError);
  }
  let coerced = false;
  const coercible = { [Symbol.toPrimitive]() { coerced = true; return 1; } };
  assert.throws(() => addon.echoInt(coercible), TypeError);
  assert.equal(coerced, false);

  assert.equal(addon.presence(), 'missing');
  assert.equal(addon.presence(undefined), 'undefined');
  assert.equal(addon.presence(null), 'null');
  assert.equal(addon.presence(0), 'value');
  const object = {};
  assert.equal(addon.invoke((...args) => {
    assert.deepEqual(args, [7, undefined, null, object]);
    assert.equal(args[3], object);
    return object;
  }, 7, undefined, null, object), object);
  for (const name of ['invoke', 'scopedInvoke']) {
    assert.equal(addon[name](() => 7), 7);
    for (const value of [new Error('sentinel'), {}, null, undefined, Symbol('error')]) {
      throwsValue(() => addon[name](() => { throw value; }), value);
      assert.equal(addon.echoInt(7), 7);
    }
  }
  assert.throws(() => addon.malformedException(), TypeError);
  assert.equal(addon.echoInt(7), 7);
  const previousValue = Object.getOwnPropertyDescriptor(Object.prototype, 'value');
  let inheritedSetterCalls = 0;
  try {
    Object.defineProperty(Object.prototype, 'value', {
      configurable: true,
      set() { ++inheritedSetterCalls; },
    });
    const value = Symbol('inherited setter');
    for (const name of ['invoke', 'scopedInvoke']) {
      throwsValue(() => addon[name](() => { throw value; }), value);
    }
    assert.equal(inheritedSetterCalls, 0);
  } finally {
    if (previousValue) Object.defineProperty(Object.prototype, 'value', previousValue);
    else delete Object.prototype.value;
  }
  assert.throws(() => addon.invoke(1), TypeError);
  assert.throws(() => addon.saveCallback(1), TypeError);
  assert.throws(() => addon.scopeBorrowed(() => 42), /left its scope/);
  assert.equal(addon.scopeRetained(() => 42), 42);

  let callback = value => value;
  const weakCallback = new WeakRef(callback);
  addon.saveCallback(callback);
  callback = null;
  await nextTurn();
  global.gc();
  await nextTurn();
  assert(weakCallback.deref(), 'Retained callback was collected');
  assert.equal(addon.callSaved(object), object);
  addon.clearSaved();
  assert.throws(() => addon.callSaved(1), Error);
  await collectUntil(() => weakCallback.deref() === undefined,
    'Released callback is still retained');

  const shortLivedValue = 246813579;
  assert.equal(addon.wasFinalized(shortLivedValue), false);
  (() => { new Counter(shortLivedValue); })();
  await collectUntil(() => addon.wasFinalized(shortLivedValue),
    'Collected Counter still holds its Dart instance');
  assert.equal(a.increment(), 22);
  await worker(path, false);
  await worker(path, true);
  assert.equal(a.value, 22);
};

module.exports.verifyInitializationFailure = function verifyInitializationFailure(path) {
  try {
    global.captureFailedEnvClass = constructor => {
      global.failedEnvInstance = new constructor();
      assert.equal(global.failedEnvInstance.increment(), 8);
    };
    assert.throws(() => require(path), /registration failed/);
    assert.equal(typeof global.failedEnvFunction, 'function');
    assert.equal(typeof global.failedEnvClass, 'function');
    const instance = global.failedEnvInstance;
    assert(instance instanceof global.failedEnvClass);
    const { Counter } = require(join(dirname(path), '..', 'core', 'addon.node'));
    const healthy = new Counter(10);
    const calls = [
      () => global.failedEnvFunction(),
      () => new global.failedEnvClass(),
      () => instance.increment(),
      () => instance.value,
      () => { instance.value = 9; },
    ];
    for (let i = 0; i < calls.length; ++i) {
      assert.throws(calls[i], /Dart environment is closed/);
      assert.equal(healthy.increment(), 11 + i);
    }
    assert.throws(() => Counter.prototype.increment.call(instance), TypeError);
    for (const marker of [new Error('registration sentinel'), {}, Symbol('registration'), null, undefined]) {
      const previous = healthy.value;
      global.failedEnvRegistrationError = () => { throw marker; };
      throwsValue(() => require(path), marker);
      assert.throws(() => global.failedEnvFunction(), /Dart environment is closed/);
      assert.equal(healthy.increment(), previous + 1);
    }
  } finally {
    delete global.captureFailedEnvClass;
    delete global.failedEnvFunction;
    delete global.failedEnvClass;
    delete global.failedEnvInstance;
    delete global.failedEnvRegistrationError;
  }
};
