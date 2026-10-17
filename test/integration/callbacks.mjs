import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {Worker, isMainThread, parentPort, workerData} from 'node:worker_threads';

const packageName = '@napi/callback-fixture';
const filename = fileURLToPath(import.meta.url);
const turn = () => new Promise(resolve => setImmediate(resolve));

function thrown(call) {
  try { call(); } catch (value) { return {value}; }
  assert.fail('Expected the call to throw');
}

function exact(call, value) {
  assert(Object.is(thrown(call).value, value), 'JS exception identity/value must survive Dart');
}

async function exactRejection(promise, value) {
  assert(promise instanceof Promise);
  try { await promise; } catch (error) {
    assert(Object.is(error, value), 'saved JS exception must retain identity through Future rejection');
    return;
  }
  assert.fail('Expected the Future to reject');
}

async function until(check, label) {
  for (let attempt = 0; attempt < 150; attempt++) {
    if (check()) return;
    await turn();
  }
  assert.fail(label);
}

async function collect(api, check, label) {
  for (let round = 0; round < 60; round++) {
    await turn();
    global.gc();
    assert.equal(api.callbackPressure(round), 999999 + round);
    await turn();
    global.gc();
    if (check()) return;
  }
  assert.fail(`${label}: not collected after bounded dual-heap pressure`);
}

function scalar(api) {
  assert.equal(api.callbackCalls(), 0);
  const seen = [];
  assert.equal(api.callTwice(function(value) {
    assert.equal(this, undefined);
    assert.equal(arguments.length, 1);
    seen.push(value);
    return value * 2;
  }, 3), 14);
  assert.deepEqual(seen, [3, 4]);
  const text = 'a\ud800b\udfffc\0\u2028\u2029😀';
  assert.equal(api.callString(s => { assert.equal(s, text); return s; }, text), text);
  for (const value of [0n, -(1n << 300n), (1n << 200n) + 1n]) {
    assert.equal(api.callBigInt(n => { assert.equal(n, value); return n; }, value), value);
  }
  for (const value of [-(1n << 63n), 9007199254740993n, (1n << 63n) - 1n]) {
    assert.equal(api.callWide(n => { assert.equal(n, value); return n; }, value), value);
  }
  for (const value of [true, false]) assert.equal(api.callBool(b => !b, value), !value);
  for (const value of [-0, NaN, Infinity, -Infinity, 1.25]) {
    assert(Object.is(api.callDouble(n => { assert(Object.is(n, value)); return n; }, value), value));
  }
  const box = new api.CallbackBox(() => 11);
  assert.equal(box.value, 11);
  assert.equal(box.apply(n => n + 3), 14);
  const named = api.CallbackBox.named(n => n + 2, 5);
  assert(named instanceof api.CallbackBox);
  assert.equal(named.value, 7);
  let setterCalls = 0;
  named.callback = n => { setterCalls++; return n * 3; };
  assert.equal(named.value, 21);
  assert.equal(setterCalls, 1, 'the setter invokes its borrowed callback synchronously');
  assert.throws(() => named.invokeStored(), /borrow|expired|active/i);
  assert.equal(setterCalls, 1, 'the saved setter callback expires when the setter returns');
  assert.equal(named.apply(n => n + 1), 22);
}

function structures(api) {
  const input = {$1: [1, 2], label: 'a\ud800'};
  let returned;
  const result = api.callRecord(row => {
    assert.notEqual(row, input);
    assert.notEqual(row.$1, input.$1);
    assert.deepEqual(row, input);
    row.$1.push(3);
    returned = row;
    return row;
  }, input);
  assert.deepEqual(input, {$1: [1, 2], label: 'a\ud800'});
  assert.deepEqual(result, {$1: [1, 2, 3], label: 'a\ud800'});
  assert.notEqual(result, returned);
  assert.notEqual(result.$1, returned.$1);
  returned.$1[0] = 99;
  assert.equal(result.$1[0], 1);
  assert.deepEqual(api.callList(value => [...value, 3]), [1, 2, 3]);
  assert.equal(api.callNested(value => { assert.equal(value, null); return null; }, null), null);
  const nested = [[1, null], []];
  assert.deepEqual(api.callNested(value => {
    assert.notEqual(value, nested);
    assert.notEqual(value[0], nested[0]);
    value[0].push(3);
    return value;
  }, nested), [[1, null, 3], []]);
  assert.deepEqual(nested, [[1, null], []]);
}

async function voidResult(api) {
  let reads = 0;
  const value = Object.defineProperty({}, 'then', {
    get() { reads++; throw Error('void result must not be inspected'); },
  });
  assert.equal(api.callVoid(n => { assert.equal(n, 7); return value; }), 42);
  assert.equal(reads, 0);
  const reason = {unobservedVoidResult: true};
  const pending = Promise.reject(reason);
  let unhandled = false;
  let handled = false;
  process.once('unhandledRejection', (error, promise) => {
    assert.equal(error, reason);
    assert.equal(promise, pending);
    unhandled = true;
  });
  process.once('rejectionHandled', promise => {
    assert.equal(promise, pending);
    handled = true;
  });
  assert.equal(api.callVoid(() => pending), 42);
  await until(() => unhandled, 'void callback must not install a hidden rejection observer');
  pending.catch(() => {});
  await until(() => handled, 'rejectionHandled identifies the original discarded Promise');
}

function validation(api) {
  let invoked = 0;
  const callback = n => { invoked++; return n; };
  const before = api.callbackCalls();
  for (const value of [undefined, null, 1, 'callback', {}, []]) {
    assert.throws(() => api.callTwice(value, 1), TypeError);
  }
  assert.throws(() => api.callTwice(), TypeError);
  assert.throws(() => api.callTwice(callback), TypeError);
  assert.throws(() => api.callTwice(callback, 1.5), RangeError);
  assert.throws(() => api.callTwice(callback, 9007199254740992), RangeError);
  assert.throws(() => new api.callTwice(callback, 1), TypeError);
  assert.equal(api.callbackCalls(), before);
  assert.equal(invoked, 0);
  assert.equal(api.optionalCallback(), -1);
  assert.equal(api.optionalCallback(undefined), -1);
  assert.equal(api.optionalCallback(null), -1);
  assert.equal(api.optionalCallback(callback), 3);
  assert.equal(api.namedCallback({callback}), 3);
  assert.equal(api.namedCallback({callback, value: undefined}), 3);
  assert.equal(api.namedCallback({callback, value: 8}), 8);
  for (const value of [undefined, null, {}, {callback: undefined}, {callback: null}, {callback, extra: 1}]) {
    assert.throws(() => api.namedCallback(value), TypeError);
  }
  let getters = 0;
  assert.throws(() => api.namedCallback({get callback() { getters++; return callback; }}), TypeError);
  assert.equal(getters, 0);
  const box = new api.CallbackBox(() => 4);
  assert.throws(() => Reflect.apply(box.apply, {}, [callback]), TypeError);
  assert.equal(box.apply(callback), 4);
  assert.throws(() => api.CallbackBox.named(), TypeError);
  assert.throws(() => api.CallbackBox.named(null, 1), TypeError);
  assert.throws(() => api.CallbackBox.named(callback), TypeError);
  assert.throws(() => api.CallbackBox.named(() => 'bad', 1), TypeError);
  assert.throws(() => Reflect.construct(api.CallbackBox.named, [callback, 1]), TypeError);
  const setter = Object.getOwnPropertyDescriptor(api.CallbackBox.prototype, 'callback').set;
  assert.throws(() => setter.call(box), TypeError);
  assert.throws(() => setter.call({}, callback), TypeError);
  assert.throws(() => { box.callback = undefined; }, TypeError);
  assert.throws(() => { box.callback = () => 'bad'; }, TypeError);
  assert.equal(box.value, 4, 'a failed callback result does not update the scalar field');
  box.callback = n => n + 2;
  assert.equal(box.value, 6);
  assert.throws(() => box.invokeStored(), /borrow|expired|active/i);
}

function reentry(api) {
  const recurse = depth => api.callTwice(n => depth === 0 ? n : recurse(depth - 1) + n, 1);
  assert.equal(recurse(4), 93);
  let outer = 0;
  let inner = 0;
  assert.equal(api.callTwice(value => {
    outer++;
    assert.equal(api.saveCallback(n => { inner++; return n + 2; }), 3);
    assert.throws(() => api.invokeSaved(), /borrow|expired|active/i);
    return value;
  }, 2), 5);
  assert.equal(outer, 2, 'closing an inner frame must preserve the outer callback');
  assert.equal(inner, 2, 'expired inner callbacks never enter JS');
  api.clearSavedCallback();
}

async function errors(api) {
  let traps = 0;
  const hostile = new Proxy({}, {
    get() { traps++; throw Error('error payload inspection'); },
    getPrototypeOf() { traps++; throw Error('error prototype inspection'); },
  });
  const revoked = Proxy.revocable({}, {});
  revoked.revoke();
  for (const value of [Error('exact callback'), {exact: true}, 17, Symbol('exact'), null, undefined, hostile, revoked.proxy]) {
    exact(() => api.callTwice(() => { throw value; }, 1), value);
    assert.equal(api.catchAndContinue(() => { throw value; }, n => n * 2), 10);
    assert.throws(() => api.replaceThrow(() => { throw value; }), /replacement Dart error/);
    assert.equal(api.saveThrow(() => { throw value; }), 1);
    exact(() => api.rethrowSaved(), value);
    await exactRejection(api.rethrowSavedFuture(), value);
    api.clearSavedError();
    assert.equal(api.callTwice(n => n, 2), 5, 'a caught JS throw must clear pending exception state');
  }
  assert.equal(traps, 0);
}

function conversionErrors(api) {
  let invoked = 0;
  assert.throws(() => api.callbackUnsafeArgument(() => { invoked++; return 1; }), RangeError);
  assert.equal(api.catchArgumentFailure(() => { invoked++; return 1; }), 1);
  assert.throws(
    () => api.callbackArgumentOrder(() => { invoked++; return 1; }),
    error => !(error instanceof RangeError) && /callback argument getter/.test(error.message),
    'all Dart structural arguments are snapshotted before host scalar validation');
  assert.equal(invoked, 0, 'argument conversion fails before exposing the callback');
  for (const value of [undefined, null, '1', true, {}]) {
    assert.throws(() => api.callTwice(() => value, 1), TypeError);
  }
  for (const value of [1.5, 9007199254740992, Infinity, NaN]) {
    assert.throws(() => api.callTwice(() => value, 1), RangeError);
  }
  assert.throws(() => api.callWide(() => 1n << 63n, 1n), RangeError);
  assert.throws(() => api.callWide(() => 1, 1n), TypeError);
  assert.throws(() => api.callBool(() => 1, true), TypeError);
  assert.throws(() => api.callString(() => 1, 'x'), TypeError);
  assert.equal(api.catchAndContinue(() => 'bad', n => n + 1), 6);
  assert.equal(api.catchAndContinue(() => 9007199254740992, n => n + 1), 6);
  assert.throws(() => api.callNested(() => undefined, null), TypeError);
  for (const value of [null, {}, [1, 'bad'], [, 2]]) {
    assert.throws(() => api.callList(() => value), TypeError);
  }
  let gets = 0;
  const accessor = [1];
  Object.defineProperty(accessor, '0', {get() { gets++; return 1; }});
  assert.throws(() => api.callList(() => accessor), TypeError);
  assert.equal(gets, 0);
  for (const value of [Error('callback reflection'), {reflection: true}, Symbol('reflection'), null, undefined]) {
    const result = new Proxy([1], {getOwnPropertyDescriptor() { throw value; }});
    exact(() => api.callList(() => result), value);
    const callback = new Proxy(n => n, {apply() { throw value; }});
    exact(() => api.callTwice(callback, 1), value);
    assert.equal(api.catchAndContinue(callback, n => n + 1), 6);
  }
  assert.equal(api.callTwice(n => n, 1), 3);
}

function savedError(api) {
  const value = {saved: true};
  assert.equal(api.saveThrow(() => { throw value; }), 1);
  return new WeakRef(value);
}

function savedCallback(api) {
  const callback = n => n + 1;
  assert.equal(api.saveCallback(callback), 2);
  return new WeakRef(callback);
}

async function resources(api) {
  for (const [id, fails] of [[1, false], [2, true]]) {
    const resource = new api.CallbackResource(id);
    const failure = {resource: id};
    let closing;
    const invoke = () => resource.apply(n => {
      assert.equal(n, id);
      closing = resource.close();
      assert(closing instanceof Promise);
      assert.equal(api.callbackCleanups(id), 0, 'callback reentry keeps the accepted receiver lease');
      assert.throws(() => resource.apply(v => v));
      if (fails) throw failure;
      return n + 1;
    });
    if (fails) exact(invoke, failure);
    else assert.equal(invoke(), id + 1);
    await closing;
    assert.equal(api.callbackCleanups(id), 1);
    assert.equal(resource.close(), closing);
  }
}

async function worker(held) {
  await new Promise((resolve, reject) => {
    const current = new Worker(new URL(import.meta.url), {workerData: {held}});
    const timeout = setTimeout(() => {
      current.terminate().catch(() => {});
      reject(Error('callback Worker timed out'));
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
    for (let round = 0; round < 2; round++) { await worker(false); await worker(true); }
    return;
  }
  const api = await import(packageName);
  switch (name) {
    case 'scalars': scalar(api); break;
    case 'structures': structures(api); break;
    case 'void': await voidResult(api); break;
    case 'validation': validation(api); break;
    case 'many': {
      let count = 0;
      assert.equal(api.callMany(n => { count++; return n; }, 100_000), 4_999_950_000);
      assert.equal(count, 100_000);
      break;
    }
    case 'reentry': reentry(api); break;
    case 'exact-errors': await errors(api); break;
    case 'conversion-errors': conversionErrors(api); break;
    case 'stored-errors': {
      const weak = savedError(api);
      for (let round = 0; round < 12; round++) {
        await turn(); global.gc(); api.callbackPressure(round); await turn();
        assert(weak.deref(), 'Dart-owned thrown value must survive its callback frame');
        exact(() => api.rethrowSaved(), weak.deref());
      }
      api.clearSavedError();
      await collect(api, () => weak.deref() === undefined, 'released saved error');
      break;
    }
    case 'expired-gc': {
      const weak = savedCallback(api);
      assert.throws(() => api.invokeSaved(), /borrow|expired|active/i);
      await collect(api, () => weak.deref() === undefined, 'expired callback function');
      assert.throws(() => api.invokeSaved(), /borrow|expired|active/i);
      api.clearSavedCallback();
      assert.equal(api.callTwice(n => n, 1), 3);
      break;
    }
    case 'scheduled': {
      let calls = 0;
      assert.equal(api.scheduleMicrotaskCallback(n => { calls++; return n; }), 2);
      assert.equal(api.scheduleCallback(n => { calls++; return n; }), 2);
      await until(() => api.callbackMicrotaskState() !== 0 && api.callbackTimerState() !== 0, 'scheduled callbacks must complete');
      assert.equal(api.callbackMicrotaskState(), 1);
      assert.equal(api.callbackTimerState(), 1);
      assert.equal(calls, 2, 'escaped microtask/Timer adapters fail before calling JS');
      let queued = false;
      assert.equal(api.saveCallback(n => {
        queueMicrotask(() => {
          assert.throws(() => api.invokeSaved(), /borrow|expired|active/i);
          queued = true;
        });
        return n;
      }), 1);
      assert.equal(queued, false, 'JS microtasks run after the binding call exits');
      await until(() => queued, 'JS microtask must see the saved adapter expired');
      api.clearSavedCallback();
      break;
    }
    case 'resources': await resources(api); break;
    case 'external': {
      const external = await import('@napi/callback-external');
      assert.deepEqual(Object.keys(external), ['plainCallback']);
      assert.equal(external.plainCallback(n => n + 1, 3), 4);
      assert.throws(() => external.plainCallback(), TypeError);
      assert.throws(() => external.plainCallback(n => 'bad', 1), TypeError);
      const error = {external: true};
      exact(() => external.plainCallback(() => { throw error; }, 1), error);
      break;
    }
    case 'workers-with-main':
      assert.equal(api.callTwice(n => n, 2), 5);
      await worker(false); await worker(true);
      assert.equal(api.callTwice(n => n, 3), 7);
      break;
    default: throw Error(`Unknown callback scenario: ${name}`);
  }
}

if (!isMainThread) {
  const api = await import(packageName);
  assert.equal(api.callTwice(n => n + 1, 2), 7);
  assert.equal(api.saveCallback(n => n), 1);
  const error = {worker: true};
  api.saveThrow(() => { throw error; });
  exact(() => api.rethrowSaved(), error);
  api.callbackPressure(1);
  if (workerData.held) {
    setInterval(() => {}, 1000);
    parentPort.postMessage('ready');
  }
} else if (process.argv[2]) {
  await scenario(process.argv[2]);
} else {
  const cases = ['scalars', 'structures', 'void', 'validation', 'many', 'reentry',
    'exact-errors', 'conversion-errors', 'stored-errors', 'expired-gc', 'scheduled',
    'resources', 'external', 'worker-only', 'workers-with-main'];
  for (const name of cases) {
    const result = spawnSync(process.execPath, ['--expose-gc', '--unhandled-rejections=throw', filename, name], {
      encoding: 'utf8', timeout: 30_000, maxBuffer: 4 * 1024 * 1024,
    });
    assert.ifError(result.error);
    assert.equal(result.signal, null, `${name}: ${result.stderr}`);
    assert.equal(result.status, 0, `${name}: ${result.stdout}\n${result.stderr}`);
    console.log(`Callback contract: ${name} passed`);
  }
  console.log(`Callback contract: ${cases.length} fresh-process scenarios passed`);
}
