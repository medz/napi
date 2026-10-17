import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {Worker, isMainThread, parentPort, workerData} from 'node:worker_threads';

const filename = fileURLToPath(import.meta.url);
const packageName = '@napi/streams-fixture';
const tick = () => new Promise(resolve => setImmediate(resolve));

async function outcome(promise, value, done = false) {
  assert(promise instanceof Promise);
  const result = await promise;
  assert.equal(Object.getPrototypeOf(result), null);
  assert.deepEqual(Object.keys(result).sort(), ['done', 'value']);
  assert.equal(result.done, done);
  assert.deepEqual(result.value, value);
  return result.value;
}

async function collect(iterator) {
  assert.equal(iterator[Symbol.asyncIterator](), iterator);
  const values = [];
  for await (const value of iterator) values.push(value);
  return values;
}

async function until(test, message) {
  for (let i = 0; i < 100; i++) {
    if (test()) return;
    await tick();
  }
  assert.fail(message);
}

async function basic(api) {
  assert.equal(api.streamCalls(), 0);
  const iterator = api.range();
  assert.equal(api.streamCalls(), 1, 'factory executes synchronously');
  assert.equal(iterator[Symbol.asyncIterator](), iterator);
  assert(!('then' in iterator));
  assert(!Object.keys(api).some(name => name.startsWith('$napi')));
  assert.throws(() => new api.range(), TypeError);
  assert.throws(() => new iterator.next(), TypeError);
  assert.throws(() => new iterator.return(), TypeError);
  await assert.rejects(Reflect.apply(iterator.next, {}, []), TypeError);
  await assert.rejects(Reflect.apply(iterator.return, {}, []), TypeError);
  await outcome(iterator.next(), 0);
  await outcome(iterator.next(), 1);
  await outcome(iterator.next(), 2);
  await outcome(iterator.next(), undefined, true);
  await outcome(iterator.next(), undefined, true);
  await outcome(iterator.return(), undefined, true);
  assert.deepEqual(await collect(api.range(0)), []);
  assert.deepEqual(await collect(api.range(undefined)), [0, 1, 2]);
  assert.deepEqual(await collect(api.generated(4)), [0, 1, 2, 3]);
  assert.deepEqual(await collect(api.voidItems()), [undefined, undefined]);
  assert.throws(() => api.range('bad'), TypeError);
  assert.throws(() => api.range(1.5), RangeError);
  assert.throws(() => api.range(-1), /stream-factory-error/);
  const concurrent = api.range(3);
  const results = await Promise.all(Array.from({length: 5}, () => concurrent.next()));
  assert.deepEqual(results.map(result => [result.value, result.done]),
    [[0, false], [1, false], [2, false], [undefined, true], [undefined, true]]);

  const box = new api.StreamBox(12);
  assert.deepEqual(await collect(box.values), [12]);
  assert.deepEqual(await collect(box.add()), [13]);
  assert.deepEqual(await collect(api.StreamBox.label()), ['StreamBox']);
  assert.throws(() => Reflect.apply(box.add, {}, []), TypeError);
  const copied = await collect(api.pointItems({x: 7}));
  assert.deepEqual(copied, [{x: 7}]);
  const row = {$1: box, peers: [box, null]};
  const rows = api.rowItems(row);
  row.peers.length = 0;
  assert.deepEqual(await collect(rows), [{$1: box, peers: [box, null]}]);
  const source = new Map([['box', box], ['null', null]]);
  const maps = api.mapItems(source);
  source.clear();
  assert.deepEqual([...((await collect(maps))[0])], [['box', box], ['null', null]]);
  const [both] = await collect(api.compositeItems());
  assert.equal(both.left, 11);
  assert.equal(both.right, 13);
  assert.equal(both instanceof api.StreamLeft, false);
  assert.equal(both instanceof api.StreamRight, false);
  assert.equal((await collect(api.rightItems(both)))[0], both);
}

async function values(api) {
  const text = 'a\ud800b\udfffc\0\u2028\u2029😀';
  assert.deepEqual(await collect(api.textItems([text, '', null])), [text, '', null]);
  const doubles = [-0, NaN, Infinity, -Infinity, 1.25];
  const returned = await collect(api.doubleItems(doubles));
  assert(doubles.every((value, index) => Object.is(value, returned[index])));
  const wide = [-(1n << 63n), 9007199254740993n, (1n << 63n) - 1n];
  assert.deepEqual(await collect(api.wideItems(wide)), wide);
  assert.deepEqual(await collect(api.hugeItems([1n << 300n])), [1n << 300n]);
  let reads = 0;
  const thenable = {get then() { reads++; throw Error('must not read item then'); }};
  const promised = Promise.resolve(17);
  const revoked = Proxy.revocable({}, {}); revoked.revoke();
  const items = [null, undefined, false, 0, -0, NaN, 'text', 1n, Symbol('item'),
    {}, [], () => 3, new Map(), new Uint8Array([1]), thenable, promised, revoked.proxy];
  for (const expected of items) {
    const iterator = api.echoItems(expected);
    const result = await iterator.next();
    assert.equal(result.done, false);
    assert(Object.is(result.value, expected));
    await outcome(iterator.next(), undefined, true);
  }
  assert.equal(reads, 0, 'Stream<T> never adopts a thenable item');
  const polluted = api.echoItems(thenable);
  const emptyItem = api.echoItems(undefined);
  Object.defineProperty(Object.prototype, 'then', {
    configurable: true, get() { throw Error('outer result prototype was assimilated'); },
  });
  try {
    const a = await polluted.next();
    const b = await emptyItem.next();
    const end = await polluted.next();
    assert.equal(a.value, thenable);
    assert.equal(b.value, undefined);
    assert.equal(end.done, true);
  } finally { delete Object.prototype.then; }
  assert.equal(reads, 0);
}

async function demand(api) {
  const unopened = new api.IntFeed();
  const lazy = unopened.values;
  assert.equal(unopened.listens, 0);
  await outcome(lazy.return(), undefined, true);
  assert.equal(unopened.listens, 0);
  assert.equal(unopened.cancels, 0);
  const feed = new api.IntFeed();
  const iterator = feed.values;
  const first = iterator.next();
  assert.equal(feed.listens, 1);
  feed.emit(1);
  await outcome(first, 1);
  assert(feed.pauses > 0, 'single-subscription source pauses without demand');
  feed.emit(2);
  feed.emit(3);
  const pending = [iterator.next(), iterator.next(), iterator.next()];
  feed.emit(4);
  assert.deepEqual((await Promise.all(pending)).map(value => value.value), [2, 3, 4]);
  const second = feed.values;
  await assert.rejects(second.next(), /already been listened|subscription/i);
  const final = iterator.next();
  await until(() => feed.resumes > 0, 'single-subscription resumes when demand stays open');
  await outcome(iterator.return(), undefined, true);
  await outcome(final, undefined, true);
  await outcome(iterator.return(), undefined, true);
  assert.equal(feed.cancels, 1);

  const broadcast = new api.IntFeed(true);
  const left = broadcast.values;
  const right = broadcast.values;
  const a = left.next(), b = right.next();
  broadcast.emit(9);
  await outcome(a, 9); await outcome(b, 9);
  await left.return();
  const c = right.next(); broadcast.emit(10); await outcome(c, 10);
  broadcast.finish();
  await outcome(right.next(), undefined, true);
  assert.equal(broadcast.cancels, 1);
  const doneFeed = new api.IntFeed(true);
  const drained = doneFeed.values;
  const firstDone = drained.next(); doneFeed.emit(1); await firstDone;
  doneFeed.emit(2); doneFeed.emit(3); doneFeed.finish();
  assert.deepEqual(await collect(drained), [2, 3], 'natural done drains admitted values');
  const early = new api.IntFeed();
  const breaking = early.values;
  const read = breaking.next(); early.emit(1); await read;
  early.emit(2);
  for await (const value of breaking) { assert.equal(value, 2); break; }
  assert.equal(early.cancels, 1, 'for-await early exit calls return');
}

async function bounded(api) {
  const feed = new api.IntFeed(true);
  const iterator = feed.values;
  const first = iterator.next(); feed.emit(-1); await outcome(first, -1);
  for (let i = 0; i < 64; i++) feed.emit(i);
  assert.equal(feed.cancels, 0);
  feed.emit(64);
  assert.equal(feed.cancels, 1, 'overflow immediately cancels the subscription');
  for (let i = 0; i < 64; i++) await outcome(iterator.next(), i);
  await assert.rejects(iterator.next(), RangeError);
  await outcome(iterator.next(), undefined, true);
  await iterator.return();
  assert.equal(feed.cancels, 1);

  const snapshots = new api.SnapshotFeed();
  const rows = snapshots.values;
  const start = rows.next(); snapshots.emit(1); await outcome(start, [1]);
  snapshots.emit(2); snapshots.emit(3); snapshots.unsafe(); snapshots.emit(4);
  await outcome(rows.next(), [2]); await outcome(rows.next(), [3]);
  await assert.rejects(rows.next(), RangeError);
  await outcome(rows.next(), undefined, true);
}

async function failures(api) {
  const unsafe = api.unsafeItems();
  await outcome(unsafe.next(), 1);
  await assert.rejects(unsafe.next(), RangeError);
  await outcome(unsafe.next(), undefined, true);
  const error = api.sourceError();
  await outcome(error.next(), 7);
  await assert.rejects(error.next(), /stream-source-error/);
  await outcome(error.next(), undefined, true);
  for (const exact of [new Error('original-js-error'), null, undefined, {exact: true}]) {
    const iterator = api.callbackError(() => { throw exact; });
    await outcome(iterator.next(), 5);
    await assert.rejects(iterator.next(), reason => reason === exact);
    await outcome(iterator.next(), undefined, true);
  }
  const feed = new api.IntFeed(true);
  const iterator = feed.values;
  const first = iterator.next(); feed.emit(1); await first;
  feed.emit(2); feed.emit(3); feed.fail(); feed.emit(4);
  await outcome(iterator.next(), 2); await outcome(iterator.next(), 3);
  await assert.rejects(iterator.next(), /feed-source-error/);
  await outcome(iterator.next(), undefined, true);
  assert.equal(feed.cancels, 1);
}

async function resources(api) {
  const owner = new api.StreamOwner(1);
  const peer = new api.StreamOwner(2);
  const iterator = owner.watch(10, {delayedCancel: true, peer, peers: [owner, peer, owner]});
  const pending = iterator.next();
  let finished = false;
  const close = owner.close().then(() => { finished = true; });
  assert(api.streamEvents().includes('cancel:10'));
  await tick();
  assert.equal(finished, false);
  assert(!api.streamEvents().includes('cleanup:1'));
  assert.throws(() => owner.watch(99), /clos/i);
  const peerClose = peer.close();
  api.releaseCancel(10);
  await close; await peerClose;
  await outcome(pending, undefined, true);
  const events = api.streamEvents();
  assert(events.indexOf('cancelled:10') < events.indexOf('cleanup:1'));
  assert(events.indexOf('cancelled:10') < events.indexOf('cleanup:2'));
  assert.equal(events.filter(value => value === 'cancel:10').length, 1);
  await owner.close();
  assert.equal(api.streamEvents().filter(value => value === 'cleanup:1').length, 1);
  await outcome(iterator.return(), undefined, true);

  for (const failCleanup of [false, true]) {
    const id = failCleanup ? 4 : 3;
    const failed = new api.StreamOwner(id, failCleanup);
    const stream = failed.watch(id * 10, {failCancel: true});
    const read = stream.next();
    await assert.rejects(failed.close(), new RegExp(`${failCleanup ? 'cleanup' : 'cancel'}-error:${failCleanup ? id : id * 10}`));
    await outcome(read, undefined, true);
    await assert.rejects(stream.return(), new RegExp(`cancel-error:${id * 10}`));
    assert.equal(api.streamEvents().filter(value => value === `cleanup:${id}`).length, 1);
  }
  const idleOwner = new api.StreamOwner(5);
  const idle = idleOwner.watch(50);
  await idleOwner.close();
  assert(!api.streamEvents().includes('listen:50'));
  await outcome(idle.next(), undefined, true);
  const returnedOwner = new api.StreamOwner(6);
  const output = returnedOwner.self();
  assert.equal((await output.next()).value, returnedOwner);
  await output.return();
  assert(!api.streamEvents().includes('cleanup:6'), 'iterator return never business-disposes output resources');
  await returnedOwner.close();

  const factoryOwner = new api.StreamOwner(7);
  let factoryClose;
  const factory = factoryOwner.watch(70, {duringFactory() {
    factoryClose = factoryOwner.close();
    assert(!api.streamEvents().includes('cleanup:7'), 'factory retains the creation lease');
  }});
  await factoryClose;
  await outcome(factory.next(), undefined, true);
  const listenOwner = new api.StreamOwner(8);
  let listenClose;
  const listening = listenOwner.watch(80, {duringListen() { listenClose = listenOwner.close(); }});
  await outcome(listening.next(), undefined, true);
  await listenClose;
  assert(api.streamEvents().indexOf('cancelled:80') < api.streamEvents().indexOf('cleanup:8'));
  let token = 90;
  for (const exact of [new Error('cancel-exact'), null, undefined, {cancel: true}]) {
    const resource = new api.StreamOwner(token);
    const stream = resource.watch(token++, {duringCancel() { throw exact; }});
    const read = stream.next();
    await assert.rejects(resource.close(), reason => reason === exact);
    await outcome(read, undefined, true);
    await assert.rejects(stream.return(), reason => reason === exact);
  }
}

async function retention(api) {
  let iterator;
  const payload = (() => {
    const value = {retained: true};
    iterator = api.holdInputs(100, value, new api.StreamBox(9));
    return new WeakRef(value);
  })();
  const pending = iterator.next();
  for (let i = 0; i < 10; i++) {
    await tick(); global.gc(); api.streamPressure(i);
    assert(payload.deref(), 'pending subscription retains original generic input');
    assert(api.heldBoxAlive(), 'pending subscription retains original Dart reference');
  }
  api.emitHeld(100, 12);
  await outcome(pending, 12);
  assert(payload.deref(), 'idle iterator retains call inputs');
  await iterator.return();
  iterator = null;
  for (let i = 0; i < 100; i++) {
    await tick(); global.gc(); api.streamPressure(i);
    if (!payload.deref() && !api.heldBoxAlive()) return;
  }
  assert.fail('completed stream inputs must be released');
}

async function worker(held) {
  const thread = new Worker(new URL(import.meta.url), {workerData: {held}});
  await new Promise((resolve, reject) => {
    thread.once('error', reject);
    if (held) thread.once('message', resolve);
    else thread.once('exit', code => code === 0 ? resolve() : reject(Error(`worker ${code}`)));
  });
  if (held) await thread.terminate();
}

async function scenario(name) {
  if (name === 'worker-only') { await worker(false); await worker(true); return; }
  const api = await import(packageName);
  const tests = {basic, values, demand, bounded, failures, resources, retention};
  if (name === 'external') {
    const external = await import('@napi/streams-external');
    await basic(external); await values(external); await demand(external);
  } else if (name === 'workers-with-main') {
    await outcome(api.range(1).next(), 0);
    await worker(false); await worker(true);
    assert.deepEqual(await collect(api.range(2)), [0, 1]);
  } else if (name === 'unhandled') {
    const exact = {unhandled: true};
    const iterator = api.callbackError(() => { throw exact; });
    await iterator.next();
    let publicPromise;
    process.exitCode = 9;
    process.once('unhandledRejection', (reason, promise) => {
      assert.equal(reason, exact); assert.equal(promise, publicPromise); process.exitCode = 0;
    });
    publicPromise = iterator.next();
  } else {
    assert(tests[name], `Unknown stream scenario ${name}`);
    await tests[name](api);
  }
}

if (!isMainThread) {
  const api = await import(packageName);
  assert.deepEqual(await collect(api.generated(3)), [0, 1, 2]);
  if (workerData.held) {
    const feed = new api.IntFeed();
    globalThis.pendingStream = feed.values;
    globalThis.pendingRead = globalThis.pendingStream.next();
    setInterval(() => {}, 1000);
    parentPort.postMessage('ready');
  }
} else if (process.argv[2]) {
  await scenario(process.argv[2]);
} else {
  const cases = ['basic', 'values', 'demand', 'bounded', 'failures', 'resources',
    'retention', 'external', 'unhandled', 'worker-only', 'workers-with-main'];
  for (const name of cases) {
    const result = spawnSync(process.execPath, ['--expose-gc', filename, name], {
      encoding: 'utf8', timeout: 30_000, maxBuffer: 4 * 1024 * 1024,
    });
    assert.ifError(result.error);
    assert.equal(result.signal, null, `${name}: ${result.stderr}`);
    assert.equal(result.status, 0, `${name}: ${result.stdout}\n${result.stderr}`);
    console.log(`Stream contract: ${name} passed`);
  }
  console.log(`Stream contract: ${cases.length} fresh-process scenarios passed`);
}
