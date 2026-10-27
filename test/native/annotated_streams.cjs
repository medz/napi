'use strict';

const assert = require('node:assert/strict');
const { Worker } = require('node:worker_threads');
const nextTurn = () => new Promise(resolve => setImmediate(resolve));

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

async function values(iterable) {
  const result = [];
  for await (const value of iterable) result.push(value);
  return result;
}

async function rejectsWith(promise, reason) {
  let rejected = false;
  try { await promise; } catch (error) { rejected = true; assert.equal(error, reason); }
  assert(rejected, 'Stream unexpectedly completed');
}

function source(next, close) {
  return {
    [Symbol.asyncIterator]() { return this; },
    next,
    ...(close ? { return: close } : {}),
  };
}

function worker(path, mode) {
  return new Promise((resolve, reject) => {
    const child = new Worker(`
      const { parentPort, workerData } = require('node:worker_threads');
      const addon = require(workerData.path);
      if (workerData.mode === 'active') {
        const state = new addon.StreamState();
        state.values(3, 30000).next();
        addon.delay().then(() => parentPort.postMessage(state.started ? 'active' : 'not started'));
      } else {
        addon.numbers(3, 30000);
        parentPort.postMessage('idle');
      }
    `, { eval: true, workerData: { path, mode } });
    let message;
    const timeout = setTimeout(() => {
      child.terminate();
      reject(new Error(`Stream worker did not exit: ${mode}`));
    }, 10000);
    child.on('error', reject);
    child.on('message', value => {
      message = value;
      if (mode === 'active') child.terminate().catch(reject);
    });
    child.on('exit', code => {
      clearTimeout(timeout);
      try {
        assert.equal(code, mode === 'active' ? 1 : 0);
        assert.equal(message, mode);
        resolve();
      } catch (error) { reject(error); }
    });
  });
}

module.exports = async function verifyAnnotatedStreams(path) {
  const addon = require(path);
  assert.deepEqual(await values(addon.numbers(3)), [0, 1, 2]);
  assert.deepEqual(await values(addon.nullableValues()), [1, null]);
  assert.deepEqual(await values(addon.voidValues()), [undefined, undefined]);
  assert.equal(await addon.countVoids((async function* () { yield 1; yield null; })()), 2);
  assert.equal(addon.nullableStream(), null);
  assert.equal(addon.nullableStream(null), null);
  assert.throws(() => addon.nullableStream(undefined), TypeError);
  assert.throws(() => addon.collect({ next() {} }), TypeError);
  const setupError = {};
  await rejectsWith(addon.collect({
    [Symbol.asyncIterator]() { throw setupError; },
  }), setupError);
  await assert.rejects(addon.collect({
    [Symbol.asyncIterator]() { return 1; },
  }), TypeError);
  await rejectsWith(addon.collect({
    [Symbol.asyncIterator]() { return { get next() { throw setupError; } }; },
  }), setupError);
  assert.throws(() => addon.collect({
    get [Symbol.asyncIterator]() { throw setupError; },
  }), error => error === setupError);

  const item = new addon.StreamValue(9);
  assert.deepEqual(await values(addon.repeatValue(item)), [item, null, item]);
  assert.deepEqual(await addon.collectFactory(() => addon.numbers(2)), [0, 1]);
  assert.deepEqual(await values(addon.numberFactory()(2)), [0, 1]);
  const streams = addon.streamList([addon.numbers(1), addon.numbers(2)]);
  assert.deepEqual(await Promise.all(streams.map(values)), [[0], [0, 1]]);

  const futureIterator = addon.futureValues();
  const futureStep = await futureIterator.next();
  assert.equal(futureStep.done, false);
  assert(futureStep.value instanceof Promise);
  assert.equal(await futureStep.value, 7);
  await futureIterator.return();
  let futurePulled = false;
  assert.equal(await addon.sumFutureValues(source(() => futurePulled
    ? { done: true }
    : (futurePulled = true, { done: false, value: Promise.resolve(7) }))), 7);

  for (const normalize of [value => value, value => ({ then(resolve) { resolve(value); } }), value => Promise.resolve(value)]) {
    let nextReads = 0, doneReads = 0, valueReads = 0, index = 0;
    const iterable = {
      [Symbol.asyncIterator]() { return this; },
      get next() {
        nextReads++;
        return function () {
          assert.equal(this, iterable);
          const current = index++;
          return normalize({
            get done() { doneReads++; return current === 2 ? 'done' : 0; },
            get value() { valueReads++; assert(current < 2); return current + 1; },
          });
        };
      },
    };
    assert.deepEqual(await addon.collect(iterable), [1, 2]);
    assert.equal(nextReads, 1);
    assert.equal(doneReads, 3);
    assert.equal(valueReads, 2);
  }

  for (const stage of ['throw', 'reject', 'result', 'done', 'value']) {
    const reason = {};
    let returned = 0;
    const iterable = source(() => {
      if (stage === 'throw') throw reason;
      if (stage === 'reject') return Promise.reject(reason);
      if (stage === 'result') return 1;
      return {
        get done() { if (stage === 'done') throw reason; return false; },
        get value() { throw reason; },
      };
    }, () => { returned++; return {}; });
    if (stage === 'result') await assert.rejects(addon.collect(iterable), TypeError);
    else await rejectsWith(addon.collect(iterable), reason);
    assert.equal(returned, 0);
  }
  let codecClosed = 0;
  await assert.rejects(addon.collect(source(
    () => ({ done: false, value: 'wrong' }),
    () => { codecClosed++; return Promise.reject({ secondary: true }); },
  )), TypeError);
  assert.equal(codecClosed, 1);

  const resume = deferred(), paused = deferred();
  let pulls = 0;
  const pauseResult = addon.pauseAfterFirst(source(() => {
    pulls++;
    return pulls <= 3 ? { value: pulls } : { done: true };
  }), paused.resolve, resume.promise);
  await paused.promise;
  await addon.delay();
  assert.equal(pulls, 1);
  resume.resolve();
  assert.deepEqual(await pauseResult, [1, 2, 3]);

  for (const normalize of [value => value, value => ({ then(resolve) { resolve(value); } }), value => Promise.resolve(value)]) {
    const pending = deferred(), started = deferred(), cancel = deferred();
    let returned = 0;
    const iterable = source(
      () => { started.resolve(); return pending.promise; },
      function () { assert.equal(this, iterable); returned++; return normalize({ done: false }); },
    );
    const result = addon.cancelPending(iterable, cancel.promise);
    await started.promise;
    cancel.resolve();
    assert.equal(await result, 0);
    assert.equal(returned, 1);
    pending.reject({ late: true });
    await addon.delay();
  }
  const pending = deferred(), started = deferred(), cancel = deferred(), closing = deferred();
  const closeStarted = deferred();
  let cancelled = false;
  const cancellation = addon.cancelPending(source(
    () => { started.resolve(); return pending.promise; },
    () => { closeStarted.resolve(); return closing.promise; },
  ), cancel.promise).then(value => { cancelled = true; return value; });
  await started.promise;
  cancel.resolve();
  await closeStarted.promise;
  await addon.delay();
  assert.equal(cancelled, false);
  closing.resolve({ done: true });
  assert.equal(await cancellation, 0);
  pending.resolve({ get done() { throw new Error('Cancelled next was read'); } });
  await addon.delay();

  const state = new addon.StreamState();
  for await (const value of state.values()) {
    assert.equal(value, 0);
    break;
  }
  assert.equal(state.finished, true);
  assert.equal(state.emitted, 1);
  const queued = addon.numbers(3, 1);
  assert.equal(queued[Symbol.asyncIterator](), queued);
  assert.deepEqual(await Promise.all([queued.next(), queued.next(), queued.next(), queued.next()]), [
    { value: 0, done: false }, { value: 1, done: false },
    { value: 2, done: false }, { value: undefined, done: true },
  ]);
  assert.throws(() => queued.next.call({}), TypeError);
  assert.throws(() => queued.return.call(Object.create(Object.getPrototypeOf(queued))), TypeError);
  const stopping = new addon.StreamState();
  const iterator = stopping.values(3, 20);
  const waiting = iterator.next();
  await addon.delay();
  assert.equal(stopping.started, true);
  assert.deepEqual(await iterator.return(), { value: undefined, done: true });
  assert.deepEqual(await waiting, { value: undefined, done: true });
  assert.equal(stopping.finished, true);

  const inFlight = addon.numbers(1, 10).next();
  global.gc();
  await nextTurn();
  global.gc();
  assert.deepEqual(await inFlight, { value: 0, done: false });
  const abandonedState = new addon.StreamState();
  async function abandon() {
    const iterator = abandonedState.values(100);
    assert.deepEqual(await iterator.next(), { value: 0, done: false });
    return new WeakRef(iterator);
  }
  const abandoned = await abandon();
  for (let round = 0; round < 64; round++) {
    await nextTurn();
    global.gc();
    await addon.delay();
    if (abandoned.deref() === undefined && abandonedState.finished) break;
  }
  assert.equal(abandoned.deref(), undefined, 'Idle iterator remained retained');
  assert.equal(abandonedState.finished, true, 'Collected iterator did not cancel its subscription');
  assert.equal(abandonedState.emitted, 1);
  await worker(path, 'idle');
  await worker(path, 'active');
};
