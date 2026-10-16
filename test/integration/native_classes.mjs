import assert from 'node:assert/strict';
import {Worker, isMainThread, parentPort, workerData} from 'node:worker_threads';
import {Counter, Other, randomValue, executable, createRequire, bindings, globalThis as exportedGlobal, URL as exportedUrl} from '@napi/native-fixture';

function check() {
  assert.deepEqual([createRequire(), bindings(), exportedGlobal(), exportedUrl()], [1, 2, 3, 4]);
  const descriptor = Object.getOwnPropertyDescriptor(Counter.prototype, 'value');
  assert.equal(descriptor.get.length, 0);
  assert.equal(descriptor.set.length, 1);
  const one = new Counter();
  const two = new Counter(undefined);
  assert(one instanceof Counter);
  assert.equal(one.value, 0);
  assert.equal(one.increment(), 1);
  assert.equal(one.increment(undefined), 2);
  assert.equal(one.increment(0), 2);
  assert.equal(one.named({amount: 3}), 5);
  assert.equal(one.doubleValue(), 10);
  assert.equal(two.value, 0);
  one.value = 41;
  assert.equal(one.increment(), 42);
  assert.equal(Counter.label(), 'Dart Counter');
  assert.equal(one.hidden, undefined);
  assert.equal(new Other().value, 4);
  assert.throws(() => { new Other().value = 3; }, TypeError);
  assert.throws(() => Counter(), TypeError);
  assert.throws(() => new Counter(null), TypeError);
  assert.throws(() => new Counter(2n), TypeError);
  assert.throws(() => new Counter(1.5), RangeError);
  assert.throws(() => { one.value = '1'; }, TypeError);
  assert.equal(one.value, 42);
  for (const receiver of [{}, Object.create(Counter.prototype), new Other(), null]) {
    assert.throws(() => Counter.prototype.increment.call(receiver), TypeError);
    const getter = Object.getOwnPropertyDescriptor(Counter.prototype, 'value').get;
    assert.throws(() => getter.call(receiver), TypeError);
  }
  assert.equal(one.value, 42);
  assert(randomValue() >= 0);
  assert.equal(executable(), process.execPath);
  for (let i = 0; i < 500; i++) assert.equal(new Counter(i).increment(), i + 1);
  global.gc?.();
  assert.equal(one.increment(), 43);
}
check();
if (isMainThread) {
  const again = await import('@napi/native-fixture/native');
  assert.equal(again.Counter, Counter);
  const independent = await import(import.meta.resolve('@napi/native-fixture') + '?independent');
  const foreign = new independent.Counter(9);
  assert.throws(() => Counter.prototype.increment.call(foreign), TypeError);
  assert.equal(foreign.value, 9);
  assert.equal(foreign.increment(), 10);
  for (let round = 0; round < 2; round++) {
    await Promise.all(Array.from({length: 3}, async (_, i) => {
      const hold = i === 2;
      const worker = new Worker(new URL(import.meta.url), {workerData: {hold}});
      const done = new Promise((resolve, reject) => {
        worker.once('error', reject);
        worker.once('exit', code => code === (hold ? 1 : 0) ? resolve() : reject(Error(`Worker exit ${code}`)));
      });
      if (hold) await new Promise((resolve, reject) => {
        worker.once('message', resolve); worker.once('error', reject);
      });
      if (hold) await worker.terminate();
      await done;
    }));
    check();
  }
  console.log('Generated native Counter, properties, ownership and Workers: passed');
} else if (workerData?.hold) {
  parentPort.postMessage('ready');
  setInterval(() => {}, 1000);
}
