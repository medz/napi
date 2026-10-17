// The npm artifact contains handwritten private ABI declarations. These tests
// exercise the production owned-value primitive, not generated opaque APIs.
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {Worker, isMainThread, parentPort, workerData} from 'node:worker_threads';

const packageName = '@napi/native-host-values-fixture';
const filename = fileURLToPath(import.meta.url);
const turn = () => new Promise(resolve => setImmediate(resolve));

async function collect(api, check, label) {
  for (let round = 0; round < 60; round++) {
    // Leave the job where WeakRef.deref() kept a value alive before collecting.
    await turn();
    global.gc();
    assert.equal(api.pressure(round), 999999 + round);
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
    api.pressure(round);
    await turn();
    assert(check(), `${label}: unexpectedly collected`);
  }
}

function savedObject(api, method = 'save') {
  const value = {payload: 81};
  api[method](value);
  return new WeakRef(value);
}

function makeCycle(api, functional) {
  const router = new api.HostRouter(null);
  const payload = functional ? () => router : {router};
  router.set(payload);
  return [new WeakRef(router), new WeakRef(payload)];
}

function exitCheck(check) {
  process.on('exit', code => {
    assert.equal(code, 0);
    check();
  });
}

async function valueMatrix(api) {
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
  const values = [
    {x: 1}, () => 19, Symbol('local'), Symbol.for('host-value'),
    (1n << 100n) + 3n, -(1n << 100n), null, undefined, -0, NaN,
    Infinity, true, 'a\ud800b\udfff', new Uint8Array([0, 255]),
    Object.freeze({frozen: true}), hostile, revoked.proxy, thenable, 0,
  ];
  assert.equal(values.length, 19);
  for (const value of values) {
    api.save(value);
    assert(Object.is(api.get(), value));
    await turn();
    global.gc();
    api.pressure(1);
    await turn();
    assert(Object.is(api.get(), value), 'host value changed across call/GC');
    api.clear();
    api.clear();
  }
  assert.equal(traps, 0);
}

async function worker(mode) {
  await new Promise((resolve, reject) => {
    const current = new Worker(new URL(import.meta.url), {workerData: {mode}});
    const timer = setTimeout(() => {
      current.terminate().catch(() => {});
      reject(Error(`host-value Worker ${mode} timed out`));
    }, 10_000);
    current.once('error', reject);
    current.once('exit', code => {
      clearTimeout(timer);
      try {
        assert.equal(code, mode === 'normal' ? 0 : 1);
        resolve();
      } catch (error) { reject(error); }
    });
    current.once('message', value => {
      try {
        assert.equal(value, 'ready');
        if (mode !== 'normal') current.terminate().catch(reject);
      } catch (error) { reject(error); }
    });
  });
}

async function scenario(name) {
  if (name === 'worker-only' || name === 'workers-with-main') {
    // Worker-only must never load the bridge into the parent environment.
    const api = name === 'workers-with-main' ? await import(packageName) : null;
    const marker = {main: true};
    if (api) api.save(marker);
    for (let round = 0; round < 2; round++) {
      for (const mode of ['normal', 'pending', 'busy']) await worker(mode);
    }
    if (api) {
      assert.equal(api.get(), marker);
      api.clear();
    }
    return;
  }
  const api = await import(packageName);
  switch (name) {
    case 'values':
      await valueMatrix(api);
      break;
    case 'dart-only-root': {
      const weak = savedObject(api);
      await keep(api, () => weak.deref() !== undefined, 'Dart root');
      assert.equal(api.get(), weak.deref());
      api.forget(); // Only Dart carrier GC can release the private native ref.
      await collect(api, () => weak.deref() === undefined, 'Dart finalizer');
      break;
    }
    case 'overwrite-remove': {
      const first = savedObject(api);
      const second = savedObject(api);
      await collect(api, () => first.deref() === undefined, 'overwritten payload');
      assert.equal(api.get(), second.deref());
      api.clear();
      api.clear();
      await collect(api, () => second.deref() === undefined, 'removed payload');
      break;
    }
    case 'released-carrier': {
      const weak = savedObject(api);
      api.release();
      api.release();
      assert.throws(() => api.get(), Error);
      // The released Dart carrier itself remains strongly stored in _saved.
      await collect(api, () => weak.deref() === undefined, 'released payload');
      api.forget();
      break;
    }
    case 'readoption': {
      const [wrapper, payload] = (() => {
        const value = {readoption: true};
        const router = new api.HostRouter(value);
        router.pin();
        return [new WeakRef(router), new WeakRef(value)];
      })();
      await collect(api, () => wrapper.deref() === undefined, 'old JS wrapper');
      assert(payload.deref());
      let replacement = api.readopt();
      assert.equal(replacement.get(), payload.deref());
      assert.equal(api.readopt(), replacement);
      api.unpin();
      const replacementWeak = new WeakRef(replacement);
      replacement = null;
      await collect(api, () => replacementWeak.deref() === undefined &&
        payload.deref() === undefined, 'readopted wrapper and payload');
      break;
    }
    case 'explicit-cycles': {
      const cycles = [
        makeCycle(api, false), makeCycle(api, true),
        makeCycle(api, false), makeCycle(api, true),
      ];
      // Approved napi-rs ownership contract: native cross-heap strong cycles
      // require an author-provided clear/remove/cleanup edge break.
      await keep(api, () => cycles.every(pair => pair.every(ref => ref.deref())),
        'unbroken object/function cycle');
      for (const [router] of cycles.slice(0, 2)) router.deref().clear();
      // The ordinary author-visible contract only requires dropping the field.
      // These two cycles must be released by carrier GC, without private release.
      for (const [router] of cycles.slice(2)) router.deref().forget();
      await collect(api, () => cycles.every(pair => pair.every(ref =>
        ref.deref() === undefined)), 'explicitly broken cycles');
      break;
    }
    case 'zone-finalizer': {
      // This is the first owned value in a fresh Dart isolate. A lazily created
      // Finalizer must not capture this hostile business Zone.
      const weak = savedObject(api, 'zoneSave');
      assert.equal(api.zoneCount(), 0);
      api.forget();
      await collect(api, () => weak.deref() === undefined, 'root-Zone finalizer');
      assert.equal(api.zoneCount(), 0);
      break;
    }
    case 'owner-isolation': {
      const other = await import(import.meta.resolve(packageName) + '?other');
      const value = {sharedJsValue: true};
      api.save(value);
      other.save(value);
      assert.throws(() => api.wrongApi(), Error);
      assert.throws(() => api.wrongEnv(), Error);
      assert.equal(api.get(), value);
      assert.equal(other.get(), value);
      const left = new api.HostRouter(value);
      const right = new other.HostRouter(value);
      assert.throws(() => api.HostRouter.prototype.get.call(right), TypeError);
      assert.throws(() => other.HostRouter.prototype.get.call(left), TypeError);
      api.clear();
      left.clear();
      assert.equal(other.get(), value);
      assert.equal(right.get(), value);
      other.clear();
      right.clear();
      break;
    }
    case 'timer-release':
      savedObject(api);
      api.releaseLater();
      exitCheck(() => assert.equal(api.laterDone(), true));
      break;
    case 'natural-exit':
      api.save({retainedUntilShutdown: true});
      api.churn({pendingFinalizers: true});
      api.pressure(1);
      exitCheck(() => assert.equal(api.get().retainedUntilShutdown, true));
      break;
    default:
      throw Error(`Unknown private host-value scenario: ${name}`);
  }
}

if (!isMainThread) {
  const api = await import(packageName);
  api.save({worker: workerData.mode});
  api.churn({queuedFinalizers: true});
  api.pressure(1);
  global.gc();
  if (workerData.mode === 'pending') api.holdTimer();
  parentPort.postMessage('ready');
  if (workerData.mode === 'busy') {
    // Termination interrupts JavaScript while queued Dart/native finalizers
    // and persistent values still exist. No addon call runs on another thread.
    for (;;) Math.imul(19, 23);
  }
} else if (process.argv[2]) {
  await scenario(process.argv[2]);
} else {
  const cases = [
    'values', 'dart-only-root', 'overwrite-remove', 'released-carrier',
    'readoption', 'explicit-cycles', 'zone-finalizer', 'owner-isolation',
    'timer-release', 'natural-exit', 'worker-only', 'workers-with-main',
  ];
  for (const name of cases) {
    const result = spawnSync(process.execPath, ['--expose-gc', filename, name], {
      encoding: 'utf8', timeout: 20_000, maxBuffer: 4 * 1024 * 1024,
    });
    assert.ifError(result.error);
    assert.equal(result.signal, null, `${name}: ${result.stderr}`);
    assert.equal(result.status, 0, `${name}: ${result.stdout}\n${result.stderr}`);
    console.log(`Native private host values: ${name} passed`);
  }
  console.log(`Native private host values: ${cases.length} fresh-process scenarios passed`);
}
