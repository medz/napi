'use strict';

const assert = require('node:assert/strict');
const { Worker } = require('node:worker_threads');
const nextTurn = () => new Promise(resolve => setImmediate(resolve));

async function rejectsWith(promise, reason) {
  let rejected = false;
  try { await promise; } catch (error) { rejected = true; assert.equal(error, reason); }
  assert(rejected, 'Promise unexpectedly fulfilled');
}

function worker(path, mode) {
  return new Promise((resolve, reject) => {
    let message;
    const child = new Worker(`
      const { parentPort, workerData } = require('node:worker_threads');
      const addon = require(workerData.path);
      if (workerData.mode === 'finish') {
        addon.delayed(7).then(value => parentPort.postMessage(value));
      } else {
        addon.echoFuture(new Promise(() => {}));
        if (workerData.mode === 'terminate') addon.delayed(7, 30000);
        else addon.pending();
        parentPort.postMessage('pending');
      }
    `, { eval: true, workerData: { path, mode } });
    const timeout = setTimeout(() => {
      child.terminate();
      reject(new Error(`Future worker did not exit: ${mode}`));
    }, 10000);
    child.on('error', reject);
    child.on('message', value => {
      message = value;
      if (mode === 'terminate') child.terminate().catch(reject);
    });
    child.on('exit', code => {
      clearTimeout(timeout);
      try {
        assert.equal(code, mode === 'terminate' ? 1 : 0);
        assert.equal(message, mode === 'finish' ? 7 : 'pending');
        resolve();
      } catch (error) { reject(error); }
    });
  });
}

module.exports = async function verifyAnnotatedFutures(path) {
  const addon = require(path);
  assert.deepEqual(await addon.fixedThenable(), { then: null });
  const value = addon.asyncValue(7);
  assert(value instanceof Promise);
  assert.equal(await value, 7);
  assert.equal(await addon.echoFuture(Promise.resolve(9)), 9);
  assert.equal(await addon.futureWithOffset(Promise.resolve(9), 2), 11);
  assert.equal(await addon.delayed(11), 11);
  assert.equal(await addon.completeVoid(Promise.resolve('ignored')), undefined);
  assert.equal(await addon.nullableValue(Promise.resolve(null)), null);
  assert.equal(addon.nullableFuture(), null);
  assert.equal(addon.nullableFuture(null), null);
  assert.equal(await addon.nullableFuture(Promise.resolve(3)), 3);
  for (const invalid of [undefined, null, {}, 1, { then() {} }]) {
    assert.throws(() => addon.echoFuture(invalid), TypeError);
  }
  assert.throws(() => addon.nullableFuture(undefined), TypeError);
  const wrongValue = addon.echoFuture(Promise.resolve('wrong'));
  assert(wrongValue instanceof Promise);
  await assert.rejects(wrongValue, TypeError);
  await assert.rejects(addon.nullableValue(Promise.resolve(undefined)), TypeError);
  const unsafe = addon.unsafeValue();
  assert(unsafe instanceof Promise);
  await assert.rejects(unsafe, RangeError);
  await assert.rejects(addon.failNever(), /future never/);

  for (const reason of [new Error('rejected'), {}, Symbol('rejected'), null, undefined]) {
    await rejectsWith(addon.echoFuture(Promise.reject(reason)), reason);
    await rejectsWith(addon.applyAsync(1, () => { throw reason; }), reason);
    await rejectsWith(addon.echoFuture(Promise.resolve({ get then() { throw reason; } })), reason);
    assert.throws(() => addon.futureList([Promise.reject(reason), 1]), TypeError);
    assert.equal(await addon.delayed(0), 0);
    assert.throws(() => addon.futureWithOffset(Promise.reject(reason), 'wrong'), TypeError);
    assert.equal(await addon.delayed(0), 0);
  }
  assert.throws(() => addon.futureList([Promise.resolve('wrong'), 1]), TypeError);
  assert.equal(await addon.delayed(0), 0);
  const getterError = {};
  await rejectsWith(addon.mapFuture(Promise.resolve({
    get value() { throw getterError; },
  })), getterError);
  const overridden = Promise.resolve(1);
  Object.defineProperty(overridden, 'then', { get() { throw getterError; } });
  assert.throws(() => addon.echoFuture(overridden), error => error === getterError);

  const counter = new addon.AsyncCounter(3);
  assert.equal(await counter.increment(2), 5);
  assert.equal(await counter.doubled, 10);
  const inputs = [Promise.resolve(1), Promise.resolve(null)];
  const copied = addon.futureList(inputs);
  assert.notEqual(copied, inputs);
  assert.deepEqual(await Promise.all(copied), [1, null]);
  assert.equal(await addon.applyAsync(3, async number => number + 1), 4);
  assert.equal(await addon.multiplyAsync(3)(4), 12);
  assert.equal(await addon.passFuture(async promise => (await promise) * 2), 14);
  assert.equal(await addon.notifyAsync(() => Promise.resolve(99)), undefined);
  await assert.rejects(addon.applyAsync(1, () => Promise.resolve('wrong')), TypeError);

  assert.equal(await addon.thenable(13), 13);
  assert.equal(await addon.thenable(13).then(number => number + 1), 14);
  const thenableReason = {};
  await rejectsWith(addon.readThenable(Promise.reject(thenableReason)), thenableReason);
  await assert.rejects(addon.readThenable(addon.thenable(13)), TypeError);
  assert.equal(await addon.nestedFuture(), 7);
  assert.equal(await addon.readNested(Promise.resolve(8)), 8);
  assert.equal(await addon.readDeepNested(Promise.resolve(9)), 9);
  assert.equal(await addon.echoNested(Promise.resolve(10)), 10);
  assert.equal(await addon.nestedMissing(Promise.resolve(null)), true);
  assert.equal(await addon.nestedMissing(Promise.resolve(11)), false);
  assert.equal(await addon.nestedNullableValue(Promise.resolve(null)), null);
  assert.equal(await addon.nestedNullableValue(Promise.resolve(12)), 12);
  assert.equal(await addon.nestedVoid(Promise.resolve('ignored')), undefined);
  assert.equal(await addon.nestedCallback(() => Promise.resolve(13)), 13);
  await assert.rejects(addon.readNested(Promise.resolve('wrong')), TypeError);
  await assert.rejects(addon.readNested(Promise.resolve(null)), TypeError);
  await assert.rejects(addon.readNested(Promise.resolve(undefined)), TypeError);
  await assert.rejects(addon.readDeepNested(Promise.resolve(1.5)), RangeError);
  await assert.rejects(addon.echoNested(Promise.resolve(2 ** 53)), RangeError);
  for (const invalid of [1, null, undefined, { then() {} }]) {
    assert.throws(() => addon.readNested(invalid), TypeError);
  }
  const nestedReason = {};
  await rejectsWith(addon.readNested(Promise.reject(nestedReason)), nestedReason);
  await rejectsWith(addon.nestedCallback(() => Promise.reject(nestedReason)), nestedReason);
  const NativePromise = global.Promise;
  let intrinsic;
  try {
    global.Promise = class { constructor() { throw new Error('global Promise was used'); } };
    intrinsic = addon.delayed(17);
    assert(intrinsic instanceof NativePromise);
  } finally { global.Promise = NativePromise; }
  assert.equal(await intrinsic, 17);

  async function settledInput() {
    const input = Promise.resolve(19);
    const output = addon.echoFuture(input);
    const references = [new WeakRef(input), new WeakRef(output)];
    assert.equal(await output, 19);
    return references;
  }
  const references = await settledInput();
  async function allocateBytes(size) {
    const bytes = await addon.createBytes(size);
    assert.equal(bytes[0], 0);
  }
  for (let i = 0; i < 64; i++) {
    await nextTurn();
    await allocateBytes(8 * 1024 * 1024 + i);
    global.gc();
    await nextTurn();
    if (references.every(reference => reference.deref() === undefined)) break;
  }
  assert(references.every(reference => reference.deref() === undefined),
    'Settled Promise remained retained by Dart');
  await worker(path, 'finish');
  await worker(path, 'pending');
  await worker(path, 'terminate');
};
