import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {cpSync, mkdtempSync} from 'node:fs';
import {basename, dirname, join} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
import {Worker, isMainThread, parentPort, workerData} from 'node:worker_threads';

const packageName = '@napi/futures-fixture';
const filename = fileURLToPath(import.meta.url);

function promise(call) {
  let result;
  assert.doesNotThrow(() => { result = call(); }, 'Future calls never throw synchronously');
  assert(result instanceof Promise, 'Future calls return a genuine Promise');
  return result;
}

async function rejects(call, check = TypeError) {
  await assert.rejects(promise(call), check);
}

async function basic(api) {
  assert.equal(api.futureCalls(), 0, 'import must not call business code');
  assert.throws(() => new api.futureValue(1), TypeError);
  assert.equal(api.futureCalls(), 0, 'invalid construction never invokes a Future declaration');
  const first = promise(() => api.futureValue(42));
  assert.equal(api.futureCalls(), 1, 'non-async Dart declaration runs during the call');
  let observed = false;
  first.then(() => { observed = true; });
  assert.equal(observed, false, 'Promise reactions are asynchronous');
  assert.equal(await first, 42);
  assert.equal(await promise(() => api.futureVoid()), undefined);
  assert.equal(await promise(() => api.futureNullable(null)), null);
  assert.equal(await promise(() => api.futureNullable('')), '');
  assert.equal(await promise(() => api.futureBool(true)), true);
  for (const value of [-0, NaN, Infinity, -Infinity, 1.25]) {
    assert(Object.is(await promise(() => api.futureDouble(value)), value));
  }
  const text = 'a\ud800b\udfffc\0\u2028\u2029😀';
  assert.equal(await promise(() => api.futureText(text)), text);
  for (const value of [-(1n << 63n), 9007199254740993n, (1n << 63n) - 1n]) {
    assert.equal(await promise(() => api.futureWide(value)), value);
  }
  assert.equal(await promise(() => api.futureBigInt(-(1n << 300n))), -(1n << 300n));
  for (const args of [[], [undefined], [0]]) {
    const before = api.futureCalls();
    const result = promise(() => api.futureDefault(...args));
    assert.equal(api.futureCalls(), before + 1, 'Dart defaults and business effects are not deferred');
    assert.equal(await result, args[0] === 0 ? 0 : 7);
  }
  assert.equal(await promise(() => api.futureRequired({value: null})), 9);

  const input = [1, 2];
  const options = {offset: 3};
  const beforeSnapshot = api.futureCalls();
  const snapshot = promise(() => api.futureSnapshot(input, options));
  assert.equal(api.futureCalls(), beforeSnapshot + 1);
  input[0] = 99;
  input.push(100);
  options.offset = 50;
  assert.deepEqual(await snapshot, [4, 5], 'inputs are snapshotted before returning the Promise');
  assert.deepEqual(await promise(() => api.futureSnapshot([1])), [8]);
  assert.deepEqual(await promise(() => api.futureSnapshot([1], {offset: undefined})), [8]);

  const beforeBad = api.futureCalls();
  for (const value of [undefined, null, '1', {}, true]) {
    await rejects(() => api.futureValue(value));
  }
  await rejects(() => api.futureValue());
  await rejects(() => api.futureValue(1.5), RangeError);
  await rejects(() => api.futureValue(9007199254740992), RangeError);
  await rejects(() => api.futureNullable(undefined));
  await rejects(() => api.futureWide(1));
  await rejects(() => api.futureWide(1n << 63n), RangeError);
  await rejects(() => api.futureBigInt(1));
  await rejects(() => api.futureSnapshot([1, 'bad']));
  await rejects(() => api.futureSnapshot([1], {unknown: 2}));
  await rejects(() => api.futureSnapshot([1], null));
  await rejects(() => api.futureRequired({}));
  assert.equal(api.futureCalls(), beforeBad, 'invalid input never invokes the declaration');
  let reads = 0;
  const guarded = new Proxy([1], {getOwnPropertyDescriptor() {
    reads++;
    throw Error('early structural read');
  }});
  await rejects(() => api.futureInputOrder(guarded), error =>
    error instanceof TypeError && error.message.includes('requiredSecond'));
  await rejects(() => api.futureReferenceOrder(guarded, {}), error =>
    error instanceof TypeError && error.message.includes('second'));
  assert.equal(reads, 0, 'presence and direct-reference guards precede structural snapshots');
  let getterCalls = 0;
  await rejects(() => api.futureSnapshot([1], {get offset() { getterCalls++; return 2; }}));
  assert.equal(getterCalls, 0, 'options accessors are rejected without execution');
  for (const exact of [new Error('future-reflection-error'), null, undefined]) {
    await rejects(() => api.futureSnapshot([1], new Proxy({}, {
      getPrototypeOf() { throw exact; },
    })), error => error === exact);
    await rejects(() => api.futureSnapshot(new Proxy([1], {
      getOwnPropertyDescriptor() { throw exact; },
    })), error => error === exact);
  }

  await rejects(() => api.futureSyncError(), /future-sync-error/);
  await rejects(() => api.futureAsyncError(), /future-async-error/);
  await rejects(() => api.futureUnsafeResult(), RangeError);
  await rejects(() => api.futureHostileError(), error => {
    assert(error instanceof Error);
    assert.match(error.message, /futureHostileError/);
    assert.match(error.message, /error description unavailable/);
    assert(Object.hasOwn(error, 'dartStack'));
    assert.equal(typeof error.dartStack, 'string');
    return true;
  });
  await rejects(() => api.futureHostileStack(), error => {
    assert(error instanceof Error);
    assert.match(error.message, /futureHostileStack/);
    assert(Object.hasOwn(error, 'dartStack'));
    assert.match(error.dartStack, /Dart stack(?: trace)? unavailable/);
    return true;
  });
  assert.equal(await promise(() => api.futureValue(9)), 9, 'failures do not poison later calls');
  for (const mode of [0, 3, 5]) assert.equal(await promise(() => api.futureAdversarial(mode)), 17);
  for (const mode of [1, 4]) await rejects(() => api.futureAdversarial(mode), /future-first-error/);
  await rejects(() => api.futureAdversarial(2), /future-registration-error/);
  assert.deepEqual(await promise(() => api.futureReentrantCompletion()), [17], 'the first callback wins before reentrant output conversion');
  await rejects(() => api.futureReentrantError(), /future-first-reentrant-error/);

  const counter = new api.FutureCounter(3);
  assert.throws(() => Reflect.construct(counter.add, []), TypeError);
  assert.equal(await promise(() => counter.add()), 4);
  assert.equal(await promise(() => counter.current), 4);
  assert.equal(await promise(() => api.FutureCounter.label()), 'FutureCounter');
  await rejects(() => counter.add('bad'));
  await rejects(() => Reflect.apply(counter.add, {}, []));
  const getCurrent = Object.getOwnPropertyDescriptor(api.FutureCounter.prototype, 'current').get;
  await rejects(() => Reflect.apply(getCurrent, {}, []));
  assert.equal(counter.value, 4);

  const point = {x: 2};
  const constructions = api.futurePointConstructions();
  const pointResult = promise(() => api.futurePoint(point));
  assert.equal(api.futurePointConstructions(), constructions + 1, 'value construction precedes async settlement');
  point.x = 20;
  assert.deepEqual(await pointResult, {x: 2, y: 7});
  await rejects(() => api.futurePoint({x: 'bad'}));
  assert.equal(api.futurePointConstructions(), constructions + 1);

  const box = new api.FutureBox(12);
  const named = new api.Promise(6);
  assert.equal(await promise(() => api.futureNamedPromise(named)), named, 'a selected class named Promise cannot shadow the builtin capability');
  assert.equal(await promise(() => api.futureReference(box)), box);
  const row = {$1: box, peers: [box, null]};
  const rows = promise(() => api.futureRows(row));
  row.peers.length = 0;
  const result = await rows;
  assert.notEqual(result, row);
  assert.equal(result.$1, box);
  assert.deepEqual(result.peers, [box, null]);
  const sourceMap = new Map([['box', box], ['null', null]]);
  const mapped = promise(() => api.futureMap(sourceMap));
  sourceMap.clear();
  assert.deepEqual([...await mapped], [['box', box], ['null', null]]);
  const dictionary = Object.assign(Object.create(null), {one: box, empty: null});
  dictionary.__proto__ = box;
  const pendingDictionary = promise(() => api.futureDictionary(dictionary));
  dictionary.one = null;
  const copiedDictionary = await pendingDictionary;
  assert.equal(Object.getPrototypeOf(copiedDictionary), null);
  assert.equal(copiedDictionary.one, box);
  assert.equal(copiedDictionary.empty, null);
  assert(Object.hasOwn(copiedDictionary, '__proto__'));
  assert.equal(copiedDictionary.__proto__, box);
  await rejects(() => api.futureDictionary(new Map()));
  await rejects(() => api.futureDictionary({bad: {}}));
  assert.equal(await promise(() => api.futureNullableRows(null)), null);
  const nullableRows = [box, null];
  const pendingRows = promise(() => api.futureNullableRows(nullableRows));
  nullableRows.length = 0;
  assert.deepEqual(await pendingRows, [box, null]);
  await rejects(() => api.futureNullableRows(undefined));
  await rejects(() => api.futureRows({$1: box, peers: [{}]}));
  assert.equal(await promise(() => api.futureReference(box)), box);

  for (let round = 0; round < 3; round++) {
    await rejects(() => api.futureFailedReference(), RangeError);
    global.gc();
    const child = await promise(() => api.futurePartialChild());
    assert(child instanceof api.FutureChild, 'failed conversion does not commit a partial base brand');
    assert.equal(await promise(() => api.futurePartialChild()), child);
    await rejects(() => api.futureFailedExisting(child), RangeError);
    assert.equal(await promise(() => api.futurePartialChild()), child, 'rollback preserves existing identity');
  }
}

async function retention(api) {
  let box = new api.FutureBox(81);
  const held = promise(() => api.futureHold(box));
  box = null;
  let counter = new api.FutureCounter(19);
  const receiver = promise(() => counter.hold());
  counter = null;
  for (let attempt = 0; attempt < 8; attempt++) {
    await new Promise(resolve => setImmediate(resolve));
    global.gc();
    api.futurePressure(attempt);
    assert.equal(api.futureHeldAlive(), true, 'pending Dart work retains its converted reference input');
    assert.equal(api.futureReceiverAlive(), true, 'pending Dart work retains its receiver without a business closure');
  }
  api.futureComplete();
  assert.equal(await held, 81);
  assert.equal(await receiver, 19, 'pending method retains its receiver');
  for (let attempt = 0; attempt < 100; attempt++) {
    await new Promise(resolve => setImmediate(resolve));
    global.gc();
    api.futurePressure(attempt);
    if (!api.futureHeldAlive() && !api.futureReceiverAlive()) return;
  }
  assert.fail('settled operations must release both input and receiver roots');
}

async function orphan(api) {
  // No business gate or timer retains either Future, and neither public Promise
  // is saved. Acceptance must still preserve raw input and receiver lifetimes.
  promise(() => api.futureOrphan(new api.FutureBox(81)));
  promise(() => new api.FutureCounter(19).orphan());
  for (let attempt = 0; attempt < 30; attempt++) {
    await new Promise(resolve => setImmediate(resolve));
    global.gc();
    for (let allocation = 0; allocation < 16; allocation++) {
      api.futurePressure(attempt * 16 + allocation);
    }
    assert.equal(api.futureHeldAlive(), true, 'orphan Future retains its accepted raw input');
    assert.equal(api.futureReceiverAlive(), true, 'orphan Future retains its accepted raw receiver');
  }
  // The parent watchdog proves unresolved Futures alone permit natural exit.
}

async function runWorker(hold) {
  await new Promise((resolve, reject) => {
    const worker = new Worker(new URL(import.meta.url), {workerData: {hold}});
    worker.once('error', reject);
    worker.once('exit', code => {
      try { assert.equal(code, hold ? 1 : 0); resolve(); }
      catch (error) { reject(error); }
    });
    if (hold) worker.once('message', message => {
      try { assert.equal(message, 'pending'); worker.terminate().catch(reject); }
      catch (error) { reject(error); }
    });
  });
}

async function scenario(name) {
  if (name === 'worker-only') {
    for (let round = 0; round < 2; round++) await Promise.all([runWorker(false), runWorker(true)]);
    return;
  }
  const api = await import(packageName);
  switch (name) {
    case 'basic': {
      const subpath = import.meta.resolve(packageName).endsWith('.wasm') ? 'module.wasm' : 'native';
      assert.equal(await import(`${packageName}/${subpath}`), api);
      await basic(api);
      break;
    }
    case 'concurrent': {
      // Exceed the native pump's per-turn settlement budget with already-ready
      // Futures, then interleave timer-backed completions in a separate batch.
      const ready = Array.from({length: 160}, (_, i) => promise(() => api.futureValue(i)));
      assert.deepEqual(await Promise.all(ready), Array.from({length: 160}, (_, i) => i));
      const pending = Array.from({length: 32}, (_, i) => promise(() => api.futureDelay(i, i % 4)));
      assert.deepEqual(await Promise.all(pending), Array.from({length: 32}, (_, i) => i));
      break;
    }
    case 'independent': {
      // A query on the Wasm facade does not duplicate its imported dependency
      // graph. Relocate every installed artifact to prove independent owners.
      const entry = fileURLToPath(import.meta.resolve(packageName));
      const copied = mkdtempSync(join(process.cwd(), 'independent module 雪 '));
      cpSync(dirname(entry), copied, {recursive: true});
      const other = await import(pathToFileURL(join(copied, basename(entry))));
      assert.notEqual(other, api);
      const foreign = new other.FutureBox(7);
      await rejects(() => api.futureReference(foreign));
      assert.equal(await promise(() => other.futureReference(foreign)), foreign);
      assert.equal(await promise(() => api.futureValue(3)), 3);
      assert.equal(api.futureCalls(), 1);
      assert.equal(other.futureCalls(), 0);
      assert.deepEqual(await Promise.all([api.futureDelay(1, 10), other.futureDelay(2, 5)]), [1, 2]);
      break;
    }
    case 'retention':
      await retention(api);
      break;
    case 'orphan':
      await orphan(api);
      break;
    case 'liveness': {
      let settled = false;
      promise(() => api.futureDelay(42, 30)).then(value => { assert.equal(value, 42); settled = true; });
      process.on('exit', () => assert.equal(settled, true, 'Dart timer alone keeps delivery alive'));
      break;
    }
    case 'pending':
      promise(() => api.futureNever());
      break;
    case 'unhandled-event': {
      let rejected;
      let observed = false;
      process.on('unhandledRejection', (error, value) => {
        assert.equal(value, rejected);
        assert.match(error.message, /future-async-error/);
        observed = true;
      });
      rejected = promise(() => api.futureAsyncError());
      process.on('exit', () => assert.equal(observed, true, 'no hidden handler may suppress unhandled rejection'));
      break;
    }
    case 'unhandled-strict':
      promise(() => api.futureAsyncError());
      break;
    case 'workers-with-main':
      await Promise.all([promise(() => api.futureDelay(42, 30)), runWorker(false), runWorker(true)]);
      assert.equal(await promise(() => api.futureValue(4)), 4);
      break;
    default:
      throw Error(`Unknown Future scenario: ${name}`);
  }
}

if (!isMainThread) {
  const api = await import(packageName);
  if (workerData.hold) {
    promise(() => api.futureDelay(1, 60_000));
    parentPort.postMessage('pending');
  } else {
    assert.equal(await promise(() => api.futureDelay(19, 20)), 19);
    assert.equal(await promise(() => api.futureNullable(null)), null);
    await rejects(() => api.futureAsyncError(), /future-async-error/);
  }
} else if (process.argv[2]) {
  await scenario(process.argv[2]);
} else {
  const cases = ['basic', 'concurrent', 'independent', 'retention', 'orphan', 'liveness',
    'pending', 'unhandled-event', 'unhandled-strict', 'worker-only', 'workers-with-main'];
  for (const name of cases) {
    // Parent-only watchdogs cannot conceal a missing native/Wasm keepalive.
    const rejectionMode = name === 'unhandled-event' ? 'throw' : 'strict';
    const result = spawnSync(process.execPath, ['--expose-gc', `--unhandled-rejections=${rejectionMode}`, filename, name], {
      encoding: 'utf8', timeout: 20_000, maxBuffer: 4 * 1024 * 1024,
    });
    assert.ifError(result.error);
    assert.equal(result.signal, null, `${name}: ${result.stderr}`);
    if (name === 'unhandled-strict') {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /future-async-error/);
    } else {
      assert.equal(result.status, 0, `${name}: ${result.stdout}\n${result.stderr}`);
    }
    console.log(`Future contract: ${name} passed`);
  }
  console.log(`Future contract: ${cases.length} fresh-process scenarios passed`);
}
