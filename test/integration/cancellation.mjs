import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {getEventListeners} from 'node:events';
import {fileURLToPath} from 'node:url';
import {Worker, isMainThread, parentPort, workerData} from 'node:worker_threads';

const filename = fileURLToPath(import.meta.url);
const packageName = '@napi/cancellation-fixture';
const tick = () => new Promise(resolve => setImmediate(resolve));
async function until(predicate, message, api) {
  for (let i = 0; i < 150; i++) {
    await tick();
    if (api) { api.pressure(); global.gc(); await tick(); }
    if (predicate()) return;
  }
  assert.fail(message);
}
function throwsExact(callback, reason) {
  let threw = false;
  try { callback(); } catch (error) { threw = true; assert(Object.is(error, reason)); }
  assert(threw, 'expected an exact thrown reason');
}
async function rejectsExact(promise, reason) {
  assert(promise instanceof Promise);
  let rejected = false;
  try { await promise; } catch (error) { rejected = true; assert(Object.is(error, reason)); }
  assert(rejected, 'expected an exact rejected reason');
}
async function staysPending(promise) {
  let settled = false;
  promise.then(() => { settled = true; }, () => { settled = true; });
  for (let i = 0; i < 5; i++) await tick();
  assert.equal(settled, false, 'request must not pretend actual work completed');
}
const listeners = signal => getEventListeners(signal, 'abort').length;

async function admission(api) {
  const controller = new AbortController();
  assert.equal(api.check(controller.signal), false);
  assert.equal(api.optional(), false);
  assert.equal(api.optional(undefined), false);
  assert.equal(api.optional(null), false);
  assert.equal(api.named(), true);
  assert.equal(api.named({signal: controller.signal, other: controller.signal}), true);
  assert.equal(api.named({signal: controller.signal, other: null}), false);
  for (const bad of [null, undefined, 1, 'signal', {}, {aborted: false},
    Object.create(AbortSignal.prototype), new Proxy(controller.signal, {})]) {
    const before = api.entries();
    assert.throws(() => api.check(bad), TypeError);
    await assert.rejects(api.immediate(bad), TypeError);
    assert.equal(api.entries(), before);
  }
  assert.throws(() => new api.check(controller.signal), TypeError);
  const own = new AbortController();
  Object.defineProperties(own.signal, {
    aborted: {get() { throw Error('own aborted must not run'); }},
    reason: {get() { throw Error('own reason must not run'); }},
  });
  assert.equal(api.check(own.signal), false);
  own.abort('actual');
  throwsExact(() => api.check(own.signal), 'actual');
}

async function reasons(api) {
  let thenReads = 0;
  const hostile = Object.create(null, {then: {get() { thenReads++; throw Error('reason then'); }}});
  const revoked = Proxy.revocable({}, {}); revoked.revoke();
  for (const value of [undefined, null, false, 0, -0, '', 1n, Symbol('stop'), {},
    new Error('stop'), hostile, revoked.proxy]) {
    const controller = new AbortController();
    const saved = new api.SavedSignal(controller.signal);
    controller.abort(value);
    const expected = controller.signal.reason;
    const before = api.entries();
    throwsExact(() => api.check(controller.signal), expected);
    throwsExact(() => api.once(controller.signal), expected);
    throwsExact(() => new api.SavedSignal(controller.signal), expected);
    throwsExact(() => { saved.signal = controller.signal; }, expected);
    await rejectsExact(api.immediate(controller.signal), expected);
    assert.equal(api.entries(), before, 'pre-aborted input never enters business');
    assert.equal(saved.aborted, true);
    throwsExact(() => saved.check(), expected);
    saved.forget();
  }
  assert.equal(thenReads, 0, 'cancellation reasons are never assimilated');
  const controller = new AbortController();
  assert.equal(api.peekAfter(controller.signal, () => controller.abort('reentry')), true);
  const next = new AbortController();
  throwsExact(() => api.checkAfter(next.signal, () => next.abort(null)), null);
  const lateInput = new AbortController();
  api.setConversion(() => lateInput.abort('conversion'));
  const before = api.entries();
  try {
    throwsExact(() => api.guarded(lateInput.signal, {value: 1}), 'conversion');
  } finally { api.setConversion(null); }
  assert.equal(api.entries(), before, 'guard runs after every input conversion');
}

async function registrations(api) {
  const controller = new AbortController();
  const a = new api.SavedSignal(controller.signal);
  const b = new api.SavedSignal(); b.signal = controller.signal;
  assert(a.same(controller.signal)); assert(b.same(controller.signal));
  let calls = 0;
  a.listen(() => calls++); b.listen(() => calls++);
  assert.equal(listeners(controller.signal), 1, 'one host listener per live token');
  a.remove(); a.remove();
  assert.equal(listeners(controller.signal), 1);
  b.remove();
  assert.equal(listeners(controller.signal), 0);
  a.listen(() => calls++); b.listen(() => calls++);
  controller.abort('stop'); controller.abort('again');
  assert.equal(calls, 0, 'notification is queued, state is already fresh');
  assert(a.aborted);
  a.remove();
  await until(() => calls === 1, 'remaining registration notified once');
  assert.equal(listeners(controller.signal), 0);
  a.listen(() => calls++);
  assert.equal(calls, 1);
  a.remove();
  for (let i = 0; i < 3; i++) await tick();
  assert.equal(calls, 1, 'late registration removed before delivery');
  a.listen(() => calls++);
  await until(() => calls === 2, 'late registration delivered');
  a.forget(); b.forget();
}

async function hostEvents(api) {
  for (const gap of [false, true]) {
    const controller = new AbortController();
    controller.signal.addEventListener('abort', event => event.stopImmediatePropagation());
    const saved = new api.SavedSignal(controller.signal);
    let calls = 0;
    saved.listen(() => calls++);
    for (let i = 0; i < 20; i++) controller.signal.dispatchEvent(new Event('abort'));
    if (gap) await tick();
    assert.equal(calls, 0);
    controller.abort('actual');
    await until(() => calls === 1, 'real abort survives fake event and stopImmediatePropagation');
    saved.forget();
  }
}

async function cooperative(api) {
  const timer = new AbortController();
  const stopped = api.timerWork(timer.signal, 20);
  timer.abort('stop-timer');
  await rejectsExact(stopped, 'stop-timer');
  assert(api.events().includes('timer-stopped'));
  await new Promise(resolve => setTimeout(resolve, 30));
  assert(!api.events().includes('timer-fired'), 'cooperative callback stopped the actual timer');
  let id = 0;
  for (const ignore of [false, true]) {
    const controller = new AbortController();
    const task = ++id;
    const promise = api.work(controller.signal, task, {ignore});
    const reason = {task};
    controller.abort(reason);
    await until(() => api.events().includes(`request:${task}`), 'Dart observed cancellation');
    await staysPending(promise);
    api.completeWork(task, 19);
    if (ignore) assert.equal(await promise, 19);
    else await rejectsExact(promise, reason);
    assert.equal(listeners(controller.signal), 0);
    assert.equal(api.events().filter(e => e === `request:${task}`).length, 1);
  }
  const late = new AbortController();
  const promise = api.work(late.signal, 3);
  api.completeWork(3, 11);
  assert.equal(await promise, 11);
  late.abort(); await tick();
  assert(!api.events().includes('request:3'));

  const controller = new AbortController();
  let release;
  const thenable = {then(resolve) { release = resolve; }};
  const accepted = api.resolved(controller.signal, thenable);
  await until(() => release !== undefined, 'result adopted root thenable');
  controller.abort('too-late');
  await staysPending(accepted);
  release(31); assert.equal(await accepted, 31);
}

async function resources(api) {
  const cleanup = new api.CleanupSignal(9);
  const aborted = AbortSignal.abort('pre-aborted-close');
  await rejectsExact(cleanup.close(aborted), 'pre-aborted-close');
  assert(!api.events().includes('cleanup:9'));
  const actualClose = cleanup.close(new AbortController().signal);
  assert.equal(cleanup.close(aborted), actualClose, 'already closing retains cleanup identity');
  await actualClose;
  assert.equal(api.events().filter(e => e === 'cleanup:9').length, 1);
  const rejectedOwner = new api.WorkOwner(8);
  await rejectsExact(rejectedOwner.work(aborted, 80), 'pre-aborted-close');
  await rejectedOwner.close();
  assert(api.events().includes('cleanup:8'), 'rejected admission releases partial leases');
  const owner = new api.WorkOwner(10);
  const controller = new AbortController();
  const promise = owner.work(controller.signal, 11);
  const closed = owner.close();
  controller.abort('stop');
  await until(() => api.events().includes('request:11'), 'request on closing owner');
  await staysPending(closed); await staysPending(promise);
  assert(!api.events().includes('cleanup:10'));
  api.completeWork(11);
  await rejectsExact(promise, 'stop'); await closed;
  const events = api.events();
  assert(events.indexOf('finished:11') < events.indexOf('cleanup:10'));
  assert.equal(events.filter(value => value === 'cleanup:10').length, 1);
}

async function streams(api) {
  const idle = new AbortController();
  const unstarted = new api.SignalFeed(20);
  const first = unstarted.watch(idle.signal);
  idle.abort('before-listen');
  await rejectsExact(first.next(), 'before-listen');
  assert.equal(unstarted.listens, 0); assert.equal(unstarted.cancels, 0);
  assert.equal((await first.next()).done, true); await first.return(); await unstarted.close();

  const controller = new AbortController();
  const other = new AbortController();
  const feed = new api.SignalFeed(21, {delayed: true});
  const iterator = feed.watch(controller.signal, {other: other.signal});
  const accepted = iterator.next();
  feed.emit(7);
  assert.equal((await accepted).value, 7);
  const pending = iterator.next();
  other.abort(null); controller.abort('second');
  await until(() => api.events().includes('cancel:21'), 'signal cancels subscription');
  assert.equal(listeners(controller.signal), 0); assert.equal(listeners(other.signal), 0);
  await staysPending(pending);
  const closed = feed.close(); const returned = iterator.return();
  await staysPending(closed); await staysPending(returned);
  api.cancelComplete(21);
  await rejectsExact(pending, null);
  await returned; await closed;
  assert.equal((await iterator.next()).done, true);
  assert.equal(api.events().filter(e => e === 'cancel:21').length, 1);

  const source = new AbortController();
  const failed = new api.SignalFeed(22, {failCancel: true, failCleanup: true});
  const sourceIterator = failed.watch(source.signal);
  const errorRead = sourceIterator.next();
  failed.fail(); source.abort('later');
  await assert.rejects(errorRead, /source-failure:22/);
  await assert.rejects(sourceIterator.return(), /cancel-failure:22/);
  await assert.rejects(failed.close(), /cleanup-failure:22/);

  const finished = new AbortController();
  const natural = api.once(finished.signal);
  assert.equal((await natural.next()).value, 7);
  assert.equal((await natural.next()).done, true);
  finished.abort('late');
  assert.equal((await natural.next()).done, true);
}

async function retention(api) {
  const live = new AbortController();
  let calls = 0;
  const weakCallback = (() => {
    const callback = () => calls++;
    api.remember(live.signal, callback, false);
    return new WeakRef(callback);
  })();
  await until(() => !api.tokenAlive() && !weakCallback.deref() && listeners(live.signal) === 0,
    'source alone must not retain Dart token, callback or listener', api);
  live.abort(); await tick(); assert.equal(calls, 0);

  const kept = new AbortController();
  const callback = (() => {
    const value = () => calls++;
    api.remember(kept.signal, value, true);
    return new WeakRef(value);
  })();
  for (let i = 0; i < 6; i++) { await tick(); api.pressure(); global.gc(); }
  assert(api.tokenAlive()); assert(callback.deref());
  api.removeRetained();
  assert.equal(listeners(kept.signal), 0);
  await until(() => !api.tokenAlive() && !callback.deref(), 'removal releases callback and token', api);

  const saved = new api.SavedSignal();
  const weakSource = (() => {
    const signal = new AbortController().signal;
    saved.signal = signal;
    return new WeakRef(signal);
  })();
  for (let i = 0; i < 6; i++) { await tick(); api.pressure(); global.gc(); }
  assert(weakSource.deref()); assert.equal(saved.aborted, false);
  saved.forget();
  await until(() => !weakSource.deref(), 'dropping retained token releases source', api);
}

async function owners(api) {
  const external = await import('@napi/cancellation-external');
  const controller = new AbortController();
  const a = new api.SavedSignal(controller.signal);
  const b = new external.SavedSignal(controller.signal);
  let one = 0, two = 0;
  a.listen(() => { one++; assert.equal(a.aborted, true); });
  b.listen(() => two++);
  assert.equal(listeners(controller.signal), 2);
  assert.equal(external.peekAfter(controller.signal, () => {
    controller.abort('foreign-owner');
    process._tickCallback();
    assert.equal(one, 0, 'foreign owner must only queue delivery');
  }), true);
  await until(() => one === 1 && two === 1, 'each owner received once');
  a.forget(); b.forget();
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
  const tests = {admission, reasons, registrations, hostEvents, cooperative, resources, streams, retention, owners};
  if (name === 'external') {
    const external = await import('@napi/cancellation-external');
    await admission(external); await reasons(external); await registrations(external);
  } else if (name === 'workers-with-main') {
    api.check(new AbortController().signal);
    await worker(false); await worker(true); await worker(true);
    assert.equal(api.check(new AbortController().signal), false);
  } else if (name === 'unhandled') {
    const controller = new AbortController(); const exact = {unhandled: true};
    controller.abort(exact);
    let publicPromise;
    process.exitCode = 9;
    process.once('unhandledRejection', (reason, promise) => {
      assert.equal(reason, exact); assert.equal(promise, publicPromise); process.exitCode = 0;
    });
    publicPromise = api.immediate(controller.signal);
  } else if (name === 'implicit-exit') {
    const controller = new AbortController();
    globalThis.retainedSignal = new api.SavedSignal(controller.signal);
    globalThis.retainedSignal.listen(() => { throw Error('must not run at teardown'); });
  } else {
    assert(tests[name]); await tests[name](api);
  }
}

if (!isMainThread) {
  const api = await import(packageName);
  await registrations(api);
  if (workerData.held) {
    const controller = new AbortController();
    globalThis.saved = new api.SavedSignal(controller.signal);
    globalThis.saved.listen(() => {});
    controller.abort();
    setInterval(() => {}, 1000);
    parentPort.postMessage('ready');
  }
} else if (process.argv[2]) {
  await scenario(process.argv[2]);
} else {
  const cases = ['admission', 'reasons', 'registrations', 'hostEvents', 'cooperative',
    'resources', 'streams', 'retention', 'owners', 'external', 'unhandled',
    'implicit-exit', 'worker-only', 'workers-with-main'];
  for (const name of cases) {
    const result = spawnSync(process.execPath, ['--expose-gc', filename, name], {
      encoding: 'utf8', timeout: 30_000, maxBuffer: 4 * 1024 * 1024,
    });
    assert.ifError(result.error);
    assert.equal(result.signal, null, `${name}: ${result.stderr}`);
    assert.equal(result.status, 0, `${name}: ${result.stdout}\n${result.stderr}`);
    console.log(`Cancellation contract: ${name} passed`);
  }
  console.log(`Cancellation contract: ${cases.length} fresh-process scenarios passed`);
}
