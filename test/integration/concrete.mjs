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

async function resources(api) {
  const integer = new api.IntSession(101, 7);
  const decimal = new api.DoubleSession(102, 1.5);
  assert.equal(integer.isInt, true);
  assert.equal(decimal.isDouble, true);
  assert.equal(integer.self(), integer);
  assert.equal(api.echoSession(integer), integer);
  assert.equal(await integer.futureValue(), 7);
  assert.throws(() => api.echoSession(decimal), TypeError);
  assert.throws(() => new api.IntSession(103, 1.5), RangeError);
  assert.throws(() => { integer.value = 1.5; }, RangeError);
  assert.throws(() => api.widenedSession(104), TypeError);
  const nullable = new api.NullableSession(105, null);
  nullable.value = 3;
  nullable.value = null;
  assert.equal(nullable.value, null);
  assert.equal(nullable.isInt, false);
  assert.throws(() => api.echoSession(nullable), TypeError);
  const nullableClosing = nullable.shutdown();
  assert(nullableClosing instanceof Promise);
  assert.equal(nullable.shutdown(), nullableClosing);
  await nullableClosing;
  assert.equal(api.sessionShutdowns(105), 1);
  assert.equal(api.sessionCloses(105), 0);
  assert.throws(() => nullable.value);
  const named = api.IntSession.from(106, 9);
  const adopted = api.createSession(107, 11);
  assert(named instanceof api.IntSession);
  assert(adopted instanceof api.IntSession);
  assert.equal(adopted.self(), adopted);
  const invalid = integer.close(1.5);
  assert(invalid instanceof Promise);
  await assert.rejects(invalid, RangeError);
  await assert.rejects(api.NullableSession.prototype.shutdown.call(integer), TypeError);
  assert.equal(api.sessionCloses(101), 0);
  assert.equal(integer.value, 7);
  const closing = integer.close(undefined);
  assert(closing instanceof Promise);
  assert.equal(integer.close(99), closing);
  await closing;
  assert.equal(api.sessionCloses(101), 1);
  assert.equal(api.sessionCode(101), 7);
  assert.equal(api.sessionShutdowns(101), 0);
  assert.throws(() => integer.value);
  assert.throws(() => api.echoSession(integer));
  await assert.rejects(integer.futureValue());
  await assert.rejects(api.IntSession.prototype.close.call(decimal), TypeError);
  await Promise.all([decimal.close(), named.close(), adopted.close()]);

  for (const [offset, exact] of [new Error('cleanup-exact'), null, undefined].entries()) {
    const resource = new api.IntSession(110 + offset, 1);
    const rejected = resource.close(7, () => { throw exact; });
    const checked = assert.rejects(rejected, value => value === exact);
    assert.equal(resource.close(), rejected);
    await checked;
    assert.equal(api.sessionCloses(110 + offset), 1);
    assert.throws(() => resource.value);
  }
  const failed = new api.NullableSession(114, null);
  const failedClose = failed.shutdown({fail: true});
  await assert.rejects(failedClose, /session-shutdown-error/);
  assert.equal(failed.shutdown(), failedClose);
  assert.equal(api.sessionShutdowns(114), 1);
  const voidResource = new api.VoidSession(115);
  const voidClose = voidResource.close();
  assert(voidClose instanceof Promise);
  assert.equal(voidResource.close(), voidClose);
  await voidClose;
  assert.equal(api.sessionCloses(115), 1);

  let held = new api.IntSession(120, 12);
  let pending = api.holdSessions([held], 120);
  let heldClose = held.close();
  held = null;
  for (let turn = 0; turn < 4; turn++) {
    api.sessionPressure(turn); global.gc(); await tick();
  }
  assert.equal(api.sessionAlive(120), true);
  assert.equal(api.sessionCloses(120), 0, 'accepted work postpones cleanup');
  api.finishSession(120, 31);
  assert.equal(await pending, 31);
  await heldClose;
  pending = null; heldClose = null;
  assert.equal(api.sessionCloses(120), 1);
  for (let turn = 0; turn < 160 && api.sessionAlive(120); turn++) {
    await tick(); api.sessionPressure(turn); global.gc();
  }
  assert.equal(api.sessionAlive(120), false, 'settled work releases its concrete resource');

  const streamOwner = new api.IntSession(130, 13);
  const stream = streamOwner.watch(130);
  const item = await stream.next();
  assert.equal(item.value, 13);
  assert.equal(item.done, false);
  const streamClose = streamOwner.close();
  for (let turn = 0; turn < 100 && api.sessionCancels(130) === 0; turn++) await tick();
  assert.equal(api.sessionCancels(130), 1);
  assert.equal(api.sessionCloses(130), 0, 'subscription cancellation precedes cleanup');
  const done = stream.next();
  api.finishSessionCancel(130);
  await streamClose;
  assert.equal((await done).done, true);
  assert.equal(api.sessionCloses(130), 1);
  assert.equal(streamOwner.close(), streamClose);
  const unreadOwner = new api.IntSession(131, 1);
  const unread = unreadOwner.watch(131);
  await unreadOwner.close();
  assert.equal((await unread.next()).done, true);
  assert.equal(api.sessionCancels(131), 0, 'closing before demand never listens');
}

if (!isMainThread) {
  const api = await import(typeof workerData === 'string' ? workerData : workerData.name);
  if (workerData.teardown) {
    const held = new api.IntSession(200, 2);
    void held.hold(200);
    void held.close();
    parentPort.postMessage('pending');
    setInterval(() => {}, 1000);
  } else {
    await contract(api);
    await resources(api);
    parentPort.postMessage('passed');
  }
} else {
  for (const name of ['@napi/concrete-fixture', '@napi/concrete-external']) {
    const api = await import(name);
    await contract(api);
    await resources(api);
    await new Promise((resolve, reject) => {
      const worker = new Worker(new URL(import.meta.url), {workerData: name});
      let passed = false;
      worker.on('message', value => { passed = value === 'passed'; });
      worker.on('error', reject);
      worker.on('exit', code => code === 0 && passed ? resolve() : reject(Error(`worker exit ${code}`)));
    });
    await new Promise((resolve, reject) => {
      const worker = new Worker(new URL(import.meta.url), {workerData: {name, teardown: true}});
      let pending = false;
      worker.once('message', value => {
        pending = value === 'pending';
        worker.terminate().catch(reject);
      });
      worker.once('error', reject);
      worker.once('exit', code => code === 1 && pending ? resolve() : reject(Error(`teardown exit ${code}`)));
    });
    console.log(`${name}: concrete substitution, identity, resource cleanup, asynchronous retention and workers passed`);
  }
}
