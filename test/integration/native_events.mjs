import assert from 'node:assert/strict';
import {createHook} from 'node:async_hooks';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {Worker, isMainThread, parentPort, workerData} from 'node:worker_threads';

const packageName = '@napi/native-events-fixture';
const microtasks = 'sync,microtask,future,last,nested';
const filename = fileURLToPath(import.meta.url);

function onExit(check) {
  process.on('exit', code => {
    assert.equal(code, 0);
    check();
  });
}

function expectedMessages(count) {
  return Array.from({length: count}, (_, index) => `m${index},u${index}`).join(',');
}

async function runWorker(hold) {
  await new Promise((resolve, reject) => {
    const worker = new Worker(new URL(import.meta.url), {workerData: {hold}});
    worker.once('error', reject);
    worker.once('exit', code => {
      try {
        assert.equal(code, hold ? 1 : 0);
        resolve();
      } catch (error) {
        reject(error);
      }
    });
    if (hold) {
      worker.once('message', message => {
        try {
          assert.equal(message, 'pending');
          worker.terminate().catch(reject);
        } catch (error) {
          reject(error);
        }
      });
    }
  });
}

async function workers(withMain) {
  // In the worker-only case the main Node environment never loads the addon.
  const api = withMain ? await import(packageName) : null;
  if (api) api.startTimer(30, 'main-timer');
  for (let round = 0; round < 2; round++) {
    await Promise.all([runWorker(false), runWorker(true)]);
  }
  if (api) onExit(() => assert.equal(api.readEvents(), 'main-timer'));
}

async function callbackScopeReentry() {
  const contexts = new Map();
  let reentered = false;
  let armed = false;
  let primaryContext;
  let loadingPrimary = true;
  let api;
  let independent;
  const hook = createHook({
    init(id, type) {
      if (type !== 'napi:Dart') return;
      contexts.set(id, {before: 0, after: 0});
      if (loadingPrimary) primaryContext = id;
    },
    before(id) {
      if (contexts.has(id)) contexts.get(id).before++;
    },
    after(id) {
      if (!contexts.has(id)) return;
      contexts.get(id).after++;
      if (!armed || id !== primaryContext || reentered) return;
      reentered = true;
      queueMicrotask(() => {
        // Closing a Node callback scope may run JS microtasks. Neither owner
        // may remain entered, and the pump's earlier idle result must not
        // unref the new Dart timers created here.
        assert.equal(api.readEvents(), microtasks);
        assert.equal(independent.readEvents(), '');
        api.startTimer(20, 'reentrant-own');
        independent.startTimer(30, 'reentrant-other');
        global.gc();
      });
    },
  }).enable();
  api = await import(packageName);
  loadingPrimary = false;
  independent = await import(import.meta.resolve(packageName) + '?reentry');
  armed = true;
  api.enqueueMicrotasks();
  global.gc();
  onExit(() => {
    hook.disable();
    assert.equal(reentered, true);
    assert.equal(contexts.size, 2);
    assert.equal(api.readEvents(), `${microtasks},reentrant-own`);
    assert.equal(independent.readEvents(), 'reentrant-other');
    for (const counts of contexts.values()) {
      assert(counts.before > 0);
      assert.equal(counts.before, counts.after);
    }
  });
}

async function scenario(name) {
  if (name === 'worker-only' || name === 'workers-with-main') {
    await workers(name === 'workers-with-main');
    return;
  }
  if (name === 'callback-scope') {
    await callbackScopeReentry();
    return;
  }
  const api = await import(packageName);
  switch (name) {
    case 'idle':
      onExit(() => assert.equal(api.readEvents(), ''));
      break;
    case 'microtasks':
      api.enqueueMicrotasks();
      // The selected contract drains after the synchronous JS stack returns,
      // in the owner-thread uv pump. Calling a second binding must not drain
      // the queue early or hide a missing wakeup.
      assert.equal(api.readEvents(), 'sync');
      onExit(() => assert.equal(api.readEvents(), microtasks));
      break;
    case 'microtask-timer':
      api.timerFromMicrotask();
      onExit(() => assert.equal(api.readEvents(), 'before-timer,microtask-timer'));
      break;
    case 'timer-only':
      api.startTimer(30, 'timer-only');
      onExit(() => assert.equal(api.readEvents(), 'timer-only'));
      break;
    case 'timer-cancel':
      api.startTimer(60_000, 'must-not-fire');
      api.cancelTimerLater();
      onExit(() => assert.equal(api.readEvents(), 'cancelled'));
      break;
    case 'timer-order':
      api.orderedTimers();
      onExit(() => assert.equal(api.readEvents(), 'zero,after-zero,later'));
      break;
    case 'messages':
      api.sendMessages(1024);
      onExit(() => assert.equal(api.readEvents(), expectedMessages(1024)));
      break;
    case 'last-port':
      api.sendMessages(1);
      onExit(() => assert.equal(api.readEvents(), 'm0,u0'));
      break;
    case 'pending-future':
      api.leaveFuturePending();
      onExit(() => assert.equal(api.readEvents(), 'pending'));
      break;
    case 'sync-error':
      assert.throws(() => api.throwAfterMicrotask(), /native-events-sync-error/);
      onExit(() => assert.equal(api.readEvents(), 'after-sync-error'));
      break;
    case 'async-error': {
      const errors = [];
      // This handler deliberately does not call any binding or schedule work:
      // the pump must resume the pure Dart microtask tail by itself.
      process.on('uncaughtException', error => errors.push(error));
      api.failMicrotaskChain();
      onExit(() => {
        assert.equal(errors.length, 1);
        assert.match(errors[0].message, /native-events-microtask-error/);
        assert.equal(api.readEvents(), 'after-async-error');
      });
      break;
    }
    case 'timer-error': {
      const errors = [];
      process.on('uncaughtException', error => errors.push(error));
      api.failTimer();
      api.startTimer(30, 'after-timer-error');
      onExit(() => {
        assert.equal(errors.length, 1);
        assert.match(errors[0].message, /native-events-timer-error/);
        assert.equal(api.readEvents(), 'after-timer-error');
      });
      break;
    }
    case 'uncaught':
      api.failTimer();
      break;
    case 'independent': {
      const other = await import(import.meta.resolve(packageName) + '?independent');
      api.enqueueMicrotasks();
      other.sendMessages(3);
      api.startTimer(20, 'first');
      other.startTimer(30, 'second');
      onExit(() => {
        assert.equal(api.readEvents(), `${microtasks},first`);
        assert.equal(other.readEvents(), `${expectedMessages(3)},second`);
      });
      break;
    }
    default:
      throw Error(`Unknown native event scenario: ${name}`);
  }
}

if (!isMainThread) {
  const api = await import(packageName);
  if (workerData.hold) {
    api.sendMessages(2048);
    api.startTimer(60_000, 'terminated-timer-must-not-fire');
    parentPort.postMessage('pending');
  } else {
    api.enqueueMicrotasks();
    api.startTimer(20, 'worker-timer');
    onExit(() => assert.equal(api.readEvents(), `${microtasks},worker-timer`));
  }
} else if (process.argv[2]) {
  await scenario(process.argv[2]);
} else {
  const cases = [
    'idle', 'microtasks', 'microtask-timer', 'timer-only', 'timer-cancel',
    'timer-order', 'messages', 'last-port', 'pending-future', 'sync-error',
    'async-error', 'timer-error', 'uncaught', 'independent', 'callback-scope',
    'worker-only', 'workers-with-main',
  ];
  for (const name of cases) {
    // The watchdog lives in the parent. Liveness cases have no JS timer,
    // polling loop or child-process handle that could keep the addon alive.
    const result = spawnSync(process.execPath, ['--expose-gc', filename, name], {
      encoding: 'utf8', timeout: 15_000, maxBuffer: 4 * 1024 * 1024,
    });
    assert.ifError(result.error);
    assert.equal(result.signal, null, `${name}: ${result.stderr}`);
    if (name === 'uncaught') {
      assert.notEqual(result.status, 0, 'uncaught Dart error must fail Node');
      assert.match(result.stderr, /native-events-timer-error/);
    } else {
      assert.equal(result.status, 0, `${name}: ${result.stdout}\n${result.stderr}`);
    }
    console.log(`Native events: ${name} passed`);
  }
  console.log(`Native event pump: ${cases.length} fresh-process scenarios passed`);
}
