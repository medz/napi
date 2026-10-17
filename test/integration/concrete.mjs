import assert from 'node:assert/strict';
import {Worker, isMainThread, parentPort, workerData} from 'node:worker_threads';

const tick = () => new Promise(resolve => setImmediate(resolve));
async function contract(api) {
  const integer = new api.IntCell(7);
  const decimal = new api.DoubleCell(1.5);
  assert.equal(integer.isInt, true);
  assert.equal(integer.isDouble, false);
  assert.equal(decimal.isInt, false);
  assert.equal(decimal.isDouble, true);
  assert.equal(integer.value, 7);
  assert.equal(decimal.value, 1.5);
  assert.equal(api.echoInt(integer), integer);
  assert.equal(api.echoDouble(decimal), decimal);
  assert.equal(api.equivalent(integer), integer);
  assert.equal(integer.self(), integer);
  assert.equal(decimal.self(), decimal);
  assert.equal(integer.replace(9), 7);
  assert.equal(integer.value, 9);
  assert.throws(() => new api.IntCell(1.5), RangeError);
  assert.throws(() => new api.IntCell('7'), TypeError);
  assert.throws(() => new api.IntCell(), TypeError);
  assert.throws(() => api.echoInt(decimal), TypeError);
  assert.throws(() => api.echoDouble(integer), TypeError);
  assert.throws(() => { integer.value = 1.5; }, RangeError);
  assert.throws(() => integer.replace(1.5), RangeError);
  assert.throws(() => api.IntCell.prototype.replace.call(decimal, 4), TypeError);
  assert.equal(integer.value, 9);
  const named = api.IntCell.named(12);
  assert.equal(named instanceof api.IntCell, true);
  assert.equal(named.isInt, true);
  assert.equal(named.value, 12);
  const adopted = api.createInt(21);
  assert.equal(adopted instanceof api.IntCell, true);
  assert.equal(adopted.self(), adopted);
  assert.equal(adopted.value, 21);
  const derived = api.createDerived(22);
  assert.equal(derived instanceof api.IntCell, true);
  assert.equal(derived.value, 22);
  assert.equal(api.echoInt(derived), derived);
  assert.throws(() => api.widenedInt(), TypeError);
  assert.throws(() => api.ambiguousInt(), TypeError);
  assert.equal(integer.optional(), null);
  assert.equal(integer.optional(undefined), null);
  assert.equal(integer.optional(null), null);
  assert.equal(integer.optional(3), 3);
  assert.equal(integer.namedOptional(), null);
  assert.equal(integer.namedOptional({next: undefined}), null);
  assert.equal(integer.namedOptional({next: null}), null);
  assert.equal(integer.namedOptional({next: 3}), 3);
  assert.throws(() => integer.optional(1.5), RangeError);
  assert.throws(() => integer.namedOptional({next: 1.5}), RangeError);
  const nullable = new api.NullableCell(null);
  assert.equal(nullable.value, null);
  nullable.value = 2;
  assert.equal(nullable.value, 2);
  assert.throws(() => api.echoInt(nullable), TypeError);
  assert.throws(() => new api.NullableCell(), TypeError);
  assert.throws(() => new api.NullableCell(undefined), TypeError);
  assert.deepEqual(integer.nested(), [new Map([['value', 9], ['empty', null]])]);
  const batch = new api.BatchCell([new Map([['one', 1], ['none', null]])]);
  assert.deepEqual(batch.value, [new Map([['one', 1], ['none', null]])]);
  assert.throws(() => new api.BatchCell([new Map([['bad', 1.5]])]), RangeError);
  const leaf = new api.Leaf(5), leaves = new api.LeafCell(leaf);
  assert.equal(leaves.value, leaf);
  assert.equal(leaves.self(), leaves);
  assert.equal(leaves.nested()[0].get('value'), leaf);
  assert.throws(() => new api.LeafCell(integer), TypeError);
  const list = api.listCells([integer, null, named]);
  assert.deepEqual(list, [integer, null, named]);
  const map = api.mapCells(new Map([[integer, decimal]]));
  assert.equal(map.get(integer), decimal);
  assert.throws(() => api.listCells([decimal]), TypeError);
  assert.throws(() => api.mapCells(new Map([[decimal, integer]])), TypeError);
  const pair = api.pair({first: integer, second: decimal});
  assert.equal(pair.first, integer);
  assert.equal(pair.second, decimal);
  assert.throws(() => api.pair({first: decimal, second: integer}), TypeError);
  assert.equal(new api.IntNumeric(4).isInt, true);
  assert.throws(() => new api.IntNumeric(1.5), RangeError);
  assert.equal(new api.SelfBound().isLeaf, true);
  assert.equal(await integer.futureValue(), 9);
  assert.equal(await leaves.futureValue(), leaf);
  assert.equal(await api.delayedInt(integer), integer);
  const stream = integer.values();
  const first = await stream.next(), last = await stream.next();
  assert.equal(first.value, 9); assert.equal(first.done, false);
  assert.equal(last.value, undefined); assert.equal(last.done, true);
  assert.equal(await leaves.values().next().then(item => item.value), leaf);
  api.saveInt(integer);
  for (let index = 0; index < 4; index++) {
    api.pressure(); global.gc(); await tick();
  }
  assert.equal(api.savedInt(), integer);
  api.saveInt(null);
  let dropped = new api.IntCell(99);
  const weak = new WeakRef(dropped);
  const pending = api.delayedInt(dropped);
  dropped = null;
  global.gc(); await tick();
  const result = await pending;
  assert.equal(result.value, 99);
  assert.equal(weak.deref(), result);
}

if (!isMainThread) {
  await contract(await import(workerData));
  parentPort.postMessage('passed');
} else {
  for (const name of ['@napi/concrete-fixture', '@napi/concrete-external']) {
    const api = await import(name);
    await contract(api);
    await new Promise((resolve, reject) => {
      const worker = new Worker(new URL(import.meta.url), {workerData: name});
      let passed = false;
      worker.on('message', value => { passed = value === 'passed'; });
      worker.on('error', reject);
      worker.on('exit', code => code === 0 && passed ? resolve() : reject(Error(`worker exit ${code}`)));
    });
    console.log(`${name}: concrete substitution, identity, asynchronous retention and worker passed`);
  }
}
