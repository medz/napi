import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {cpSync, mkdtempSync} from 'node:fs';
import {basename, dirname, join} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
import {runInNewContext} from 'node:vm';
import {Worker, isMainThread, parentPort, workerData} from 'node:worker_threads';

const packageName = '@napi/opaque-fixture';
const filename = fileURLToPath(import.meta.url);
const turn = () => new Promise(resolve => setImmediate(resolve));

async function collect(api, check, label) {
  for (let round = 0; round < 60; round++) {
    await turn();
    global.gc();
    assert.equal(api.opaquePressure(round), 999999 + round);
    await turn();
    global.gc();
    if (check()) return;
  }
  assert.fail(`${label}: not collected after bounded dual-heap pressure`);
}

async function keep(api, check, label) {
  for (let round = 0; round < 12; round++) {
    await turn();
    global.gc();
    api.opaquePressure(round);
    await turn();
    assert(check(), `${label}: collected before its Dart owner released it`);
  }
}

async function values(api) {
  let traps = 0;
  const hostile = new Proxy({}, {
    get() { traps++; throw Error('unexpected payload get'); },
    getPrototypeOf() { traps++; throw Error('unexpected payload prototype'); },
    ownKeys() { traps++; throw Error('unexpected payload keys'); },
  });
  const revoked = Proxy.revocable({}, {});
  revoked.revoke();
  const thenable = Object.defineProperty({}, 'then', {
    get() { traps++; throw Error('unexpected payload then'); },
  });
  const router = new api.Router();
  const payloads = [
    {x: 1}, () => 19, Symbol('local'), Symbol.for('opaque'),
    (1n << 100n) + 3n, -(1n << 100n), null, undefined, -0, NaN,
    Infinity, -Infinity, true, false, 'a\ud800b\udfff', new Uint8Array([0, 255]),
    Buffer.from([3, 7]), [1, {x: 2}], Object.freeze({frozen: true}),
    hostile, revoked.proxy, thenable, Promise.resolve(42),
    runInNewContext('({foreign: true})'), 0,
  ];
  assert.equal(payloads.length, 25);
  for (const value of payloads) {
    assert(Object.is(api.identity(value), value));
    assert(Object.is(api.optional(value), value));
    router.set('value', value);
    router.value = value;
    await turn();
    global.gc();
    api.opaquePressure(1);
    assert(Object.is(router.get('value'), value));
    assert(Object.is(router.value, value));
    assert(Object.is(router.optional(value), value));
    assert.equal(router.has('value'), true);
    assert.equal(router.remove('value'), true);
    assert.equal(router.has('value'), false);
    router.clear();
  }
  assert.equal(traps, 0);
  const pair = new api.Pair('left', 42);
  assert.equal(pair.first, 'left');
  assert.equal(pair.second, 42);
  const bounded = new api.Bounded(null);
  assert.equal(bounded.value, null);
  bounded.value = undefined;
  assert.equal(bounded.value, undefined);
  assert.equal(api.forwardRouter(router), router);
  assert.equal(router.self(), router);
  assert.deepEqual(api.opaqueArray(undefined), [1, 2]);
  assert.deepEqual(api.opaqueRecord(null), {});
  assert.deepEqual(api.opaqueKey(Symbol('key')), {});
  assert.deepEqual(await api.opaqueGlobal({global: true}), new Map([['size', 1]]));
  assert.deepEqual(new api.Array('payload').numbers(), [1, 2]);
  assert.deepEqual(new api.Record().empty(), {});
  assert.equal(await api.futureRouter(router), router);
  assert.throws(() => api.Router(), TypeError);
  assert.throws(() => new api.identity(1), TypeError);
}

function presence(api) {
  const router = new api.Router();
  const before = api.opaqueCalls();
  assert.throws(() => api.identity(), TypeError);
  assert.throws(() => router.set('missing'), TypeError);
  assert.throws(() => router.put({key: 'missing'}), TypeError);
  assert.throws(() => router.put(Object.create({key: 'inherited', value: 1})), TypeError);
  assert.throws(() => api.Router.withValue(), TypeError);
  const setter = Object.getOwnPropertyDescriptor(api.Router.prototype, 'value').set;
  assert.throws(() => setter.call(router), TypeError);
  assert.equal(api.opaqueCalls(), before);
  assert.equal(api.identity(undefined), undefined);
  assert.equal(api.optional(), null);
  assert.equal(api.optional(undefined), undefined);
  assert.equal(api.optional(null), null);
  assert.equal(router.optional(), null);
  assert.equal(router.optional(undefined), undefined);
  assert.equal(api.prefix(), null);
  assert.equal(api.prefix(undefined), undefined);
  assert.equal(api.prefix('first', undefined), 'first');
  assert.equal(api.prefix('first', 0, undefined), undefined);
  assert.equal(api.prefix('first', 0), null);
  assert.throws(() => api.prefix('first', null), TypeError);
  for (const value of [null, undefined]) {
    router.put({key: 'present', value});
    assert.equal(router.has('present'), true);
    assert(Object.is(router.get('present'), value));
    assert.equal(router.remove('present'), true);
    assert.equal(router.has('present'), false);
    assert.equal(router.get('present'), null);
    setter.call(router, value);
    assert(Object.is(router.value, value));
    assert(Object.is(api.Router.withValue(value).get('initial'), value));
  }
}

function genuine(call) {
  let result;
  assert.doesNotThrow(() => { result = call(); });
  assert(result instanceof Promise, 'Future export returns a genuine Promise');
  return result;
}

async function futureValues(api) {
  for (const value of [undefined, null, -0, NaN, Infinity, 42, 1n << 100n,
    'a\ud800b\udfff', Symbol('future'), {plain: true}, () => 42]) {
    assert(Object.is(await genuine(() => api.futureIdentity(value)), value));
    assert(Object.is(await genuine(() => api.futureOptional(value)), value));
  }
  assert.equal(await api.futureOptional(), null);
  const calls = api.opaqueCalls();
  await assert.rejects(genuine(() => api.futureIdentity()), TypeError);
  assert.equal(api.opaqueCalls(), calls, 'missing input never enters Dart');
  const router = new api.Router();
  assert.equal(await router.futureGet('missing'), null);
  router.set('undefined', undefined);
  assert.equal(await router.futureGet('undefined'), undefined);
  router.value = undefined;
  assert.equal(await router.futureValue, undefined);
  router.value = null;
  assert.equal(await router.futureValue, null);
  assert.equal(await api.opaqueAwaited(undefined), undefined);
  const stored = new api.Awaited('value');
  assert.equal(await api.futureIdentity(stored), stored);
  const payloads = Array.from({length: 40}, (_, id) => ({id}));
  const results = await Promise.all(payloads.map((value, id) =>
    api.futureDelayed(value, id % 4)));
  for (let i = 0; i < payloads.length; i++) assert.equal(results[i], payloads[i]);
}

async function thenables(api) {
  const payload = {result: true};
  let gets = 0;
  let invokes = 0;
  const value = Object.defineProperty({}, 'then', {get() {
    gets++;
    assert.equal(api.identity(payload), payload, 'resolver reflection can reenter Dart');
    return function(resolve, reject) {
      assert.equal(this, value);
      invokes++;
      resolve({then(next) { next(payload); }});
      reject(Error('ignored second settlement'));
      throw Error('ignored after settlement');
    };
  }});
  assert.equal(api.identity(value), value);
  assert.equal(gets, 0, 'synchronous opaque payload never reads then');
  assert.equal(await api.futureIdentity(value), payload);
  assert.equal(gets, 1);
  assert.equal(invokes, 1);
  assert.equal(await api.futureIdentity(Promise.resolve(payload)), payload);
  const foreign = runInNewContext('Promise.resolve({foreign: true})');
  assert.equal(await api.futureIdentity(foreign), await foreign);
  for (const error of [Error('getter'), {error: true}, 23, Symbol('error'), null, undefined]) {
    const throwing = Object.defineProperty({}, 'then', {get() { throw error; }});
    await assert.rejects(genuine(() => api.futureIdentity(throwing)), failure => Object.is(failure, error));
    await assert.rejects(genuine(() => api.futureIdentity({then(_resolve, reject) { reject(error); }})),
      failure => Object.is(failure, error));
    assert.equal(await api.futureIdentity(7), 7, 'failed adoption leaves the next call usable');
  }
  const noncallable = {then: 42};
  assert.equal(await api.futureIdentity(noncallable), noncallable);
  const revoked = Proxy.revocable({}, {});
  revoked.revoke();
  await assert.rejects(api.futureIdentity(revoked.proxy), TypeError);

  let nestedCalls = 0;
  const callback = resolve => { nestedCalls++; resolve(payload); };
  const box = new api.ThenBox(callback);
  assert.equal(box.then, callback);
  assert.equal(await box.futureSelf(), payload);
  assert.equal(await api.futureThenBox(box), payload);
  assert.equal(nestedCalls, 2);
  // The Array is an opaque payload; no structural generic conversion is implied.
  const rows = await api.futureIdentity([box]);
  assert.equal(rows[0], box);
  assert.equal(rows[0].then, callback);
  assert.equal(nestedCalls, 2, 'nested reference values are not assimilated');
  const plain = new api.ThenBox(null);
  assert.equal(await plain.futureSelf(), plain);
  assert.equal(await api.futureThenBox(plain), plain);
  const router = new api.Router();
  Object.defineProperty(router, 'then', {value: resolve => resolve(19)});
  assert.equal(await api.futureRouter(router), 19, 'ordinary JS wrapper mutation follows Promise resolution');
}

function retained(api) {
  const value = {retained: true};
  const router = new api.Router();
  router.set('value', value);
  router.pin();
  return [new WeakRef(router), new WeakRef(value)];
}

function cycle(api, functional) {
  const router = new api.Router();
  const value = functional ? () => router : {router};
  router.set('cycle', value);
  return [new WeakRef(router), new WeakRef(value)];
}

function clearCycles(routers) {
  // End the loop's activation before GC; a suspended async frame may retain
  // its last iteration binding even after the array itself is emptied.
  for (const router of routers) router.clear();
  routers.length = 0;
}

async function worker(held) {
  await new Promise((resolve, reject) => {
    const current = new Worker(new URL(import.meta.url), {workerData: {held}});
    const timeout = setTimeout(() => {
      current.terminate().catch(() => {});
      reject(Error('opaque Worker timed out'));
    }, 10_000);
    current.once('error', reject);
    current.once('exit', code => {
      clearTimeout(timeout);
      try { assert.equal(code, held ? 1 : 0); resolve(); } catch (error) { reject(error); }
    });
    if (held) current.once('message', message => {
      assert.equal(message, 'ready');
      current.terminate().catch(reject);
    });
  });
}

async function scenario(name) {
  if (name === 'worker-only') {
    for (let i = 0; i < 3; i++) { await worker(false); await worker(true); }
    return;
  }
  const api = await import(packageName);
  switch (name) {
    case 'values': await values(api); break;
    case 'presence': presence(api); break;
    case 'future-values': await futureValues(api); break;
    case 'thenables': await thenables(api); break;
    case 'future-unhandled': {
      const error = {unhandled: true};
      let actual;
      process.once('unhandledRejection', (reason, promise) => {
        assert.equal(reason, error);
        assert.equal(promise, actual);
        process.exitCode = 0;
      });
      process.exitCode = 9;
      actual = api.futureIdentity({then(_resolve, reject) { reject(error); }});
      break;
    }
    case 'external': {
      const external = await import('@napi/opaque-external');
      const value = {external: true};
      assert.equal(external.plainEcho(value), value);
      assert.equal(external.plainEcho(undefined), undefined);
      assert.equal(await external.plainFuture(value), value);
      assert.equal(await external.plainFuture(undefined), undefined);
      assert.equal(await external.plainFuture({then(resolve) { resolve(42); }}), 42);
      assert.throws(() => external.plainEcho(), TypeError);
      const store = new external.PlainStore(value);
      assert.equal(store.value, value);
      store.value = undefined;
      assert.equal(store.value, undefined);
      assert.equal(await store.futureValue(), undefined);
      assert.throws(() => new external.PlainStore(), TypeError);
      break;
    }
    case 'retention': {
      const [wrapper, payload] = retained(api);
      await collect(api, () => wrapper.deref() === undefined, 'old wrapper');
      await keep(api, () => payload.deref() !== undefined, 'Dart-only payload root');
      let replacement = api.readoptRouter();
      assert.equal(replacement.get('value'), payload.deref());
      assert.equal(api.readoptRouter(), replacement);
      api.unpinRouter();
      replacement = null;
      await collect(api, () => payload.deref() === undefined, 'unrooted payload');
      break;
    }
    case 'overwrite-remove': {
      const router = new api.Router();
      const put = () => {
        const value = {version: router.size};
        router.set('value', value);
        return new WeakRef(value);
      };
      const old = put();
      const current = put();
      await collect(api, () => old.deref() === undefined, 'overwritten value');
      assert.equal(router.get('value'), current.deref());
      router.remove('value');
      await collect(api, () => current.deref() === undefined, 'removed value');
      break;
    }
    case 'cycles': {
      // Native may retain these cycles; Wasm may collect them. Portable authors
      // explicitly clear the stored edge while they still hold the wrapper.
      const pairs = [cycle(api, false), cycle(api, true)];
      const routers = pairs.map(pair => pair[0].deref());
      await keep(api, () => pairs.every(pair => pair.every(ref => ref.deref())), 'rooted cycle');
      clearCycles(routers);
      await collect(api, () => pairs.every(pair => pair.every(ref => !ref.deref())), 'broken cycles');
      break;
    }
    case 'pending': {
      let pending;
      const weak = (() => {
        const value = {pending: true};
        pending = api.waitOpaque(value);
        assert(pending instanceof Promise);
        return new WeakRef(value);
      })();
      await keep(api, () => weak.deref() !== undefined, 'pending opaque input');
      api.completeOpaque(42);
      assert.equal(await pending, 42);
      await collect(api, () => weak.deref() === undefined, 'completed opaque input');
      break;
    }
    case 'independent': {
      const entry = fileURLToPath(import.meta.resolve(packageName));
      const copied = mkdtempSync(join(process.cwd(), 'independent opaque 雪 '));
      cpSync(dirname(entry), copied, {recursive: true});
      const other = await import(pathToFileURL(join(copied, basename(entry))));
      const foreign = new other.Router();
      assert.throws(() => api.forwardRouter(foreign), TypeError);
      assert.equal(api.identity(foreign), foreign, 'opaque storage does not inspect wrapper brands');
      assert.equal(other.forwardRouter(foreign), foreign);
      break;
    }
    case 'workers-with-main':
      api.identity({main: true});
      await worker(false);
      await worker(true);
      assert.equal(api.identity(42), 42);
      break;
    default: throw Error(`Unknown opaque scenario: ${name}`);
  }
}

if (!isMainThread) {
  const api = await import(packageName);
  const router = new api.Router();
  const value = {worker: true};
  router.set('value', value);
  assert.equal(router.get('value'), value);
  assert.equal(await api.futureIdentity(value), value);
  assert.equal(await api.futureIdentity(undefined), undefined);
  assert.equal(await api.futureIdentity({then(resolve) { resolve(17); }}), 17);
  router.pin();
  api.opaquePressure(1);
  if (workerData.held) {
    setInterval(() => {}, 1000);
    parentPort.postMessage('ready');
  }
} else if (process.argv[2]) {
  await scenario(process.argv[2]);
} else {
  const cases = ['values', 'presence', 'future-values', 'thenables', 'future-unhandled',
    'external', 'retention', 'overwrite-remove',
    'cycles', 'pending', 'independent', 'worker-only', 'workers-with-main'];
  for (const name of cases) {
    const result = spawnSync(process.execPath, ['--expose-gc', filename, name], {
      encoding: 'utf8', timeout: 25_000, maxBuffer: 4 * 1024 * 1024,
    });
    assert.ifError(result.error);
    assert.equal(result.signal, null, `${name}: ${result.stderr}`);
    assert.equal(result.status, 0, `${name}: ${result.stdout}\n${result.stderr}`);
    console.log(`Opaque contract: ${name} passed`);
  }
  console.log(`Opaque contract: ${cases.length} fresh-process scenarios passed`);
}
