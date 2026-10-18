import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {Worker, isMainThread, parentPort, workerData} from 'node:worker_threads';
import {runInNewContext} from 'node:vm';

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
  assert.equal(setterCalls, 1);
  assert.equal(named.invokeStored(), 63);
  assert.equal(setterCalls, 2, 'the Dart field retains its callback');
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
  assert.equal(box.invokeStored(), 8);
}

function reentry(api) {
  const recurse = depth => api.callTwice(n => depth === 0 ? n : recurse(depth - 1) + n, 1);
  assert.equal(recurse(4), 93);
  let outer = 0;
  let inner = 0;
  assert.equal(api.callTwice(value => {
    outer++;
    assert.equal(api.saveCallback(n => { inner++; return n + 2; }), 3);
    assert.equal(api.invokeSaved(), 7);
    return value;
  }, 2), 5);
  assert.equal(outer, 2, 'inner registrations preserve the outer callback');
  assert.equal(inner, 4);
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

async function scalarIntrinsics(api) {
  const external = await import('@napi/callback-external');
  const isSafeInteger = Number.isSafeInteger;
  try {
    for (const replacement of [() => true, () => false]) {
      Number.isSafeInteger = replacement;
      assert.equal(api.callTwice(n => n, 2), 5);
      assert.deepEqual(api.callList(values => values), [1, 2]);
      assert.equal(await api.callAsync(async n => n, 7), 7);
      assert.equal(external.plainCallback(n => n, 8), 8);
      assert.equal(await external.plainAsyncCallback(async n => n, 9), 9);
      let invoked = 0;
      assert.throws(() => api.callbackUnsafeArgument(() => { invoked++; return 1; }), RangeError);
      assert.equal(invoked, 0, 'unsafe Dart callback arguments never reach JavaScript');
      for (const value of [0.5, 2 ** 53]) {
        assert.throws(() => api.callTwice(() => value, 1), RangeError);
        assert.throws(() => api.callList(() => [value]), RangeError);
        assert.throws(() => external.plainCallback(() => value, 1), RangeError);
        await assert.rejects(api.callAsync(async () => value, 1), RangeError);
        await assert.rejects(external.plainAsyncCallback(async () => value, 1), RangeError);
      }
    }
  } finally {
    Number.isSafeInteger = isSafeInteger;
  }
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

async function identity(api) {
  const callback = n => n + 2;
  assert.equal(api.sameCallback(callback, callback), true);
  assert.equal(api.sameCallback(callback, n => n + 2), false);
  assert.equal(api.registerCallback(callback), 1);
  assert.equal(api.sameWideCallback(callback), false, 'bigint and number policies need different adapters');
  assert.equal(api.registerCallback(callback), 2);
  assert.equal(api.unregisterCallback(callback), true);
  assert.equal(api.registeredCallbackCount(), 1);
  assert.equal(api.invokeRegistered(0, 5), 7, 'removing one business root preserves the other');
  assert.equal(api.unregisterCallback(callback), true);
  assert.equal(api.unregisterCallback(callback), false);
  assert.equal(api.registeredCallbackCount(), 0);
  api.rememberCallbackWeakly(callback);
  await collect(api, () => api.weakCallbackCount() === 0, 'JS function alone must not pin a Dart adapter');
  assert.equal(callback(7), 9);
  assert.equal(api.sameCallback(callback, callback), true, 'an adapter can be recreated after collection');
  for (let i = 0; i < 1000; i++) api.rememberCallbackWeakly(n => n + i);
  await collect(api, () => api.weakCallbackCount() === 0, 'temporary callback adapters');

  let reentered = 0;
  const removing = n => {
    reentered++;
    assert.equal(api.unregisterCallback(removing), reentered === 1);
    return n + 1;
  };
  api.registerCallback(removing);
  assert.equal(api.callTwice(removing, 2), 7);
  assert.equal(api.registeredCallbackCount(), 0);
}

async function asyncValues(api) {
  assert.equal(await api.callAfter(n => n + 1, 9), 10);
  assert.equal(await api.callAsync(async n => n * 2, 7), 14);
  assert.equal(await api.callAsync(function(n) {
    assert.equal(this, undefined); assert.equal(arguments.length, 1);
    return Promise.resolve(n + 1);
  }, 4), 5);
  const text = 'a\ud800\0\udfff雪😀';
  assert.equal(await api.callAsyncString(async value => value, text), text);
  assert.equal(await api.callAsyncWide(async n => n + 1n, 9007199254740993n), 9007199254740994n);
  assert.deepEqual(await api.callAsyncRecord(async row => ({$1: [...row.$1, 3], label: row.label})),
    {$1: [1, null, 3], label: 'row'});
  assert.equal(await api.optionalAsyncCallback(), -1);
  assert.equal(await api.optionalAsyncCallback(undefined), -1);
  assert.equal(await api.optionalAsyncCallback(null), -1);
  assert.equal(await api.optionalAsyncCallback(async n => n + 1), 4);
  assert.equal(await api.callAsyncVoid(async () => {}), undefined);
  assert.equal(await api.callAsyncVoid(() => Promise.resolve(17)), undefined);
  const subclass = class extends Promise {};
  assert.equal(await api.callAsync(n => subclass.resolve(n + 1), 1), 2);
  assert.equal(await api.callAsync(() => runInNewContext('Promise.resolve(42)'), 1), 42);
  let reads = 0;
  const overridden = Promise.resolve(23);
  Object.defineProperty(overridden, 'then', {get() { reads++; throw Error('own then'); }});
  assert.equal(await api.callAsync(() => overridden, 1), 23);
  const discarded = {};
  const voidPromise = Promise.resolve(discarded);
  Object.defineProperty(discarded, 'then', {get() { reads++; throw Error('discarded result'); }});
  await api.callAsyncVoid(() => voidPromise);
  assert.equal(reads, 0, 'intrinsic Promise consumption and void result discard avoid own then');
  const calls = Array.from({length: 80}, (_, i) => api.callAsync(n =>
    new Promise(resolve => setImmediate(() => resolve(n + 1))), i));
  assert.deepEqual(await Promise.all(calls), Array.from({length: 80}, (_, i) => i + 1));
  assert.equal(await api.callAsync(async n => await api.callAsync(async x => x + 2, n), 3), 5);
}

async function asyncValidation(api) {
  let gets = 0;
  const thenable = {get then() { gets++; return resolve => resolve(1); }};
  const revoked = Proxy.revocable(Promise.resolve(1), {}); revoked.revoke();
  for (const value of [undefined, null, 1, '1', {}, thenable,
    Object.create(Promise.prototype), {[Symbol.toStringTag]: 'Promise'},
    new Proxy(Promise.resolve(1), {}), revoked.proxy]) {
    await assert.rejects(api.callAsync(() => value, 1), TypeError);
    await assert.rejects(api.callAsyncVoid(() => value), TypeError);
  }
  assert.equal(gets, 0, 'non-Promise admission must not read a then getter');
  assert.equal(await api.callAsync(() => Promise.resolve(thenable), 1), 1);
  assert.equal(gets, 1);
  await assert.rejects(api.callAsync(undefined, 1), TypeError);
  await assert.rejects(api.callAsync(async n => n, '1'), TypeError);
  for (const value of [undefined, null, '1', {}, true]) {
    await assert.rejects(api.callAsync(() => Promise.resolve(value), 1), TypeError);
  }
  for (const value of [1.5, 9007199254740992, Infinity, NaN]) {
    await assert.rejects(api.callAsync(() => Promise.resolve(value), 1), RangeError);
  }
  await assert.rejects(api.callAsyncWide(async () => 1n << 63n, 1n), RangeError);
  await assert.rejects(api.callAsyncRecord(async () => ({$1: [1, 'bad'], label: 'row'})), TypeError);
  assert.equal(await api.callAsync(async n => n + 1, 5), 6);
}

async function asyncErrors(api) {
  let traps = 0;
  const hostile = new Proxy({}, {get() { traps++; throw Error('inspected error'); }});
  const revoked = Proxy.revocable({}, {}); revoked.revoke();
  for (const error of [Error('async exact'), {exact: true}, 17, Symbol('async'), null, undefined, hostile, revoked.proxy]) {
    assert.equal(api.catchCallbackStart(() => { throw error; }), 1,
      'a Future-typed callback can throw synchronously before returning its Promise');
    exact(() => api.rethrowSaved(), error);
    api.clearSavedError();
    await exactRejection(api.callAsync(() => { throw error; }, 1), error);
    await exactRejection(api.callAsync(() => Promise.reject(error), 1), error);
    assert.equal(await api.catchAsyncError(() => Promise.reject(error)), 1);
    exact(() => api.rethrowSaved(), error);
    await exactRejection(api.rethrowSavedFuture(), error);
    api.clearSavedError();
  }
  assert.equal(traps, 0);
  assert.equal(api.catchCallbackStart(() => 1), 1);
  assert.throws(() => api.rethrowSaved(), TypeError);
  api.clearSavedError();
  for (const error of [Error('species'), Symbol('constructor'), null, undefined]) {
    const constructorThrows = Promise.resolve(1);
    Object.defineProperty(constructorThrows, 'constructor', {get() { throw error; }});
    await exactRejection(api.callAsync(() => constructorThrows, 1), error);
    const speciesThrows = Promise.resolve(2);
    Object.defineProperty(speciesThrows, 'constructor', {value: {
      get [Symbol.species]() { throw error; },
    }});
    await exactRejection(api.callAsync(() => speciesThrows, 1), error);
    assert.equal(api.catchCallbackStart(() => speciesThrows), 1);
    exact(() => api.rethrowSaved(), error); api.clearSavedError();
  }
  const weak = await (async () => {
    const error = {pendingError: true};
    assert.equal(await api.catchAsyncError(() => Promise.reject(error)), 1);
    return new WeakRef(error);
  })();
  for (let i = 0; i < 6; i++) {
    await turn(); global.gc(); api.callbackPressure(i); await turn();
    assert(weak.deref()); exact(() => api.rethrowSaved(), weak.deref());
  }
  api.clearSavedError();
  await collect(api, () => weak.deref() === undefined, 'saved async rejection');
}

async function asyncRetention(api) {
  let complete;
  const weak = (() => {
    const fn = n => new Promise(resolve => { complete = () => resolve(n + 1); });
    api.registerAsyncCallback(fn);
    assert.equal(api.rememberAsyncCallbackWeakly(fn), 0);
    return new WeakRef(fn);
  })();
  for (let i = 0; i < 6; i++) {
    await turn(); global.gc(); api.callbackPressure(i); await turn();
    assert(weak.deref(), 'Dart callback registration owns the JS function');
  }
  const result = api.invokeAsyncRegistered(0, 9);
  assert.equal(api.unregisterAsyncCallback(weak.deref()), true);
  assert.equal(api.unregisterAsyncCallback(weak.deref()), false);
  for (let i = 0; i < 6; i++) {
    await turn(); global.gc(); api.callbackPressure(i); await turn();
    assert(weak.deref(), 'an accepted invocation retains its callback until settlement');
    assert.equal(api.matchesWeakAsyncCallback(0, weak.deref()), true,
      'the typed Dart adapter remains canonical while an invocation is pending');
  }
  complete(); complete = undefined;
  assert.equal(await result, 10);
  await collect(api, () => weak.deref() === undefined && api.weakCallbackCount() === 0,
    'settled async callback and its typed adapter');

  let invoked = 0;
  const removing = n => {
    invoked++; assert.equal(api.unregisterAsyncCallback(removing), invoked === 1);
    return Promise.resolve(n + 1);
  };
  api.registerAsyncCallback(removing);
  assert.equal(await api.invokeAsyncRegistered(0, 3), 4);
  assert.equal(invoked, 1);
  assert.equal(await api.callAsync(removing, 1), 2, 'unregister does not globally revoke the adapter');
}

async function asyncResources(api) {
  for (const [id, fails] of [[11, false], [12, true]]) {
    const resource = new api.CallbackResource(id);
    const error = {resource: id};
    let complete, closing;
    const result = resource.applyAsync(value => {
      assert.equal(value, id);
      closing = resource.close();
      assert.equal(api.callbackCleanups(id), 0);
      return new Promise((resolve, reject) => { complete = () => fails ? reject(error) : resolve(value + 1); });
    });
    for (let i = 0; i < 4; i++) {
      await turn(); global.gc(); api.callbackPressure(i); await turn();
      assert.equal(api.callbackCleanups(id), 0, 'accepted async callback holds the resource lease');
    }
    await assert.rejects(resource.applyAsync(async n => n));
    complete();
    if (fails) await exactRejection(result, error);
    else assert.equal(await result, id + 1);
    await closing;
    assert.equal(api.callbackCleanups(id), 1);
    assert.equal(resource.close(), closing);
  }
  const later = new api.CallbackResource(13);
  const operation = later.applyLater(n => n + 1);
  const closing = later.close();
  assert.equal(await operation, 14);
  await closing;
  assert.equal(api.callbackCleanups(13), 1);
  for (const [id, fails] of [[14, false], [15, true]]) {
    const cleanup = new api.CallbackCleanup(id);
    const error = {cleanup: id};
    let complete, calls = 0;
    const close = cleanup.close(() => {
      calls++;
      return new Promise((resolve, reject) => { complete = () => fails ? reject(error) : resolve(); });
    });
    assert.equal(cleanup.close(() => { throw Error('second cleanup'); }), close);
    for (let i = 0; i < 4; i++) {
      await turn(); global.gc(); api.callbackPressure(i); await turn();
      assert.equal(api.callbackCleanups(id), 0);
    }
    complete();
    if (fails) await exactRejection(close, error); else await close;
    assert.equal(calls, 1); assert.equal(api.callbackCleanups(id), 1);
  }
}

async function foreignOwner(api) {
  const other = await import('@napi/callback-external');
  let complete;
  const pending = api.callAsync(n => new Promise(resolve => { complete = () => resolve(n + 1); }), 41);
  await until(() => complete !== undefined, 'first owner invokes its callback');
  await new Promise((resolve, reject) => setImmediate(() => {
    try {
      assert.equal(other.plainCallback(n => {
        complete();
        process._tickCallback();
        return n + 1;
      }, 2), 3);
      resolve();
    } catch (error) { reject(error); }
  }));
  assert.equal(await pending, 42, 'foreign-owner Promise delivery must queue before Dart entry');
  assert.equal(await other.plainAsyncCallback(async n => n + 2, 1), 3);
}

async function worker(held, queued = false) {
  await new Promise((resolve, reject) => {
    const current = new Worker(new URL(import.meta.url), {workerData: {held, queued}});
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
    case 'late-rejection': break;
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
    case 'scalar-intrinsics': await scalarIntrinsics(api); break;
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
    case 'retained-gc': {
      const weak = savedCallback(api);
      for (let i = 0; i < 6; i++) {
        await turn(); global.gc(); api.callbackPressure(i); await turn();
        assert(weak.deref()); assert.equal(api.invokeSaved(), 6);
      }
      api.clearSavedCallback();
      await collect(api, () => weak.deref() === undefined, 'cleared callback function');
      assert.equal(api.callTwice(n => n, 1), 3);
      break;
    }
    case 'scheduled': {
      let calls = 0;
      assert.equal(api.scheduleMicrotaskCallback(n => { calls++; return n; }), 2);
      assert.equal(api.scheduleCallback(n => { calls++; return n; }), 2);
      await until(() => api.callbackMicrotaskState() !== 0 && api.callbackTimerState() !== 0, 'scheduled callbacks must complete');
      assert.equal(api.callbackMicrotaskState(), -1);
      assert.equal(api.callbackTimerState(), -1);
      assert.equal(calls, 4, 'microtask and Timer retain ordinary Dart callbacks');
      let queued = false;
      assert.equal(api.saveCallback(n => {
        if (n === 1) queueMicrotask(() => {
          assert.equal(api.invokeSaved(), 5);
          queued = true;
        });
        return n;
      }), 1);
      assert.equal(queued, false, 'JS microtasks run after the binding call exits');
      await until(() => queued, 'JS microtask must be able to use the saved adapter');
      api.clearSavedCallback();
      break;
    }
    case 'resources': await resources(api); break;
    case 'identity': await identity(api); break;
    case 'async-values': await asyncValues(api); break;
    case 'async-validation': await asyncValidation(api); break;
    case 'async-errors': await asyncErrors(api); break;
    case 'async-retention': await asyncRetention(api); break;
    case 'async-resources': await asyncResources(api); break;
    case 'foreign-owner': await foreignOwner(api); break;
    case 'pending-natural-exit': {
      api.registerAsyncCallback(() => new Promise(() => {}));
      api.invokeAsyncRegistered(0, 1);
      break;
    }
    case 'queued-teardown': await worker(false, true); break;
    case 'external': {
      const external = await import('@napi/callback-external');
      assert.deepEqual(Object.keys(external), ['plainAsyncCallback', 'plainCallback']);
      assert.equal(external.plainCallback(n => n + 1, 3), 4);
      assert.throws(() => external.plainCallback(), TypeError);
      assert.throws(() => external.plainCallback(n => 'bad', 1), TypeError);
      const error = {external: true};
      exact(() => external.plainCallback(() => { throw error; }, 1), error);
      assert.equal(await external.plainAsyncCallback(async n => n + 1, 3), 4);
      await exactRejection(external.plainAsyncCallback(() => Promise.reject(error), 1), error);
      await assert.rejects(external.plainAsyncCallback(n => n, 1), TypeError);
      break;
    }
    case 'workers-with-main':
      assert.equal(api.callTwice(n => n, 2), 5);
      await worker(false); await worker(true);
      assert.equal(api.callTwice(n => n, 3), 7);
      break;
    default: throw Error(`Unknown callback scenario: ${name}`);
  }
  if (name !== 'void') {
    await turn(); await turn();
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
  assert.equal(await api.callAsync(async n => n + 2, 5), 7);
  api.registerAsyncCallback(() => new Promise(() => {}));
  api.invokeAsyncRegistered(0, 1);
  if (workerData.queued) {
    for (let i = 0; i < 1000; i++) api.callAsync(() => Promise.resolve(i), i);
    process._tickCallback();
    process.exit(0);
  }
  if (workerData.held) {
    setInterval(() => {}, 1000);
    parentPort.postMessage('ready');
  }
} else if (process.argv[2]) {
  await scenario(process.argv[2]);
  if (process.argv[2] === 'late-rejection') {
    const api = await import(packageName);
    // Run after the scenario's final checks; an unexpected rejection must still fail.
    setImmediate(() => {
      api.callAsync(() => Promise.reject(new Error('callback-late-rejection')), 1);
    });
  }
} else {
  const cases = ['late-rejection', 'scalars', 'structures', 'void', 'validation', 'many', 'reentry',
    'exact-errors', 'conversion-errors', 'scalar-intrinsics', 'stored-errors', 'retained-gc', 'scheduled',
    'resources', 'identity', 'async-values', 'async-validation', 'async-errors',
    'async-retention', 'async-resources', 'foreign-owner', 'pending-natural-exit',
    'queued-teardown', 'external', 'worker-only', 'workers-with-main'];
  for (const name of cases) {
    const result = spawnSync(process.execPath, ['--expose-gc', '--unhandled-rejections=throw', filename, name], {
      encoding: 'utf8', timeout: 30_000, maxBuffer: 4 * 1024 * 1024,
    });
    assert.ifError(result.error);
    assert.equal(result.signal, null, `${name}: ${result.stderr}`);
    if (name === 'late-rejection') {
      assert.notEqual(result.status, 0, 'late unhandled rejection must fail after the last scenario assertion');
      assert.match(result.stderr, /callback-late-rejection/);
    } else {
      assert.equal(result.status, 0, `${name}: ${result.stdout}\n${result.stderr}`);
    }
    console.log(`Callback contract: ${name} passed`);
  }
  console.log(`Callback contract: ${cases.length} fresh-process scenarios passed`);
}
