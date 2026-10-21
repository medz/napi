import assert from 'node:assert/strict';
import {Worker, isMainThread, parentPort, workerData} from 'node:worker_threads';
import {runInNewContext} from 'node:vm';

const packageName = '@napi/callback-fixture';
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
  binaryValues(api);
  payloadValues(api);
}

function payloadValues(api) {
  const box = new api.CallbackBox(() => 11);
  const payload = {raw: true};
  const labels = Object.assign(Object.create(null), {one: payload, absent: undefined, nil: null});
  const input = {values: new Map([['first', [{value: 1}, null]]]), payloads: labels, references: [box, null], resource: null};
  let returned;
  const result = api.callContainers(value => {
    assert.notEqual(value, input); assert.notEqual(value.values, input.values);
    assert.notEqual(value.values.get('first'), input.values.get('first'));
    assert.deepEqual(value.values.get('first'), [{value: 1, step: 7}, null]);
    assert.equal(Object.getPrototypeOf(value.payloads), null);
    assert.notEqual(value.payloads, labels);
    assert.equal(value.payloads.one, payload);
    assert.equal(Object.hasOwn(value.payloads, 'absent'), true);
    assert.equal(value.payloads.absent, undefined); assert.equal(value.payloads.nil, null);
    assert.equal(value.references[0], box); assert.equal(value.references[1], null);
    returned = {...value, values: new Map([['next', [{value: 3}, null]]])};
    return returned;
  }, input);
  assert.deepEqual(input.values.get('first'), [{value: 1}, null]);
  assert.deepEqual(result.values.get('next'), [{value: 3, step: 7}, null]);
  assert.notEqual(result.values, returned.values); assert.notEqual(result.payloads, returned.payloads);
  assert.equal(result.payloads.one, payload); assert.equal(result.references[0], box);
  assert.deepEqual([...api.callKeyMap(value => {
    assert.deepEqual([...value], [[{value: 1, step: 7}, 2]]);
    return new Map([[{value: 2}, 3]]);
  })], [[{value: 2, step: 7}, 3]]);
  assert.throws(() => api.callKeyMap(() => new Map([[{value: 1}, 2], [{value: 1, step: 8}, 3]])), TypeError);
  let reads = 0;
  const accessor = Object.defineProperty({}, 'bad', {enumerable: true, get() {reads++; return payload;}});
  assert.throws(() => api.callContainers(value => ({...value, payloads: accessor}), input), TypeError);
  assert.equal(reads, 0);
  assert.deepEqual(api.callNormalized(value => {
    assert.deepEqual(value, {value: 12}); return {source: '13'};
  }, '12'), {value: 13});
  assert.throws(() => api.callNormalized(value => value, '12'), TypeError);
  assert.equal(api.callProjection(value => value.value), 42);
  assert.equal(api.readProjectionCallback(() => []), -1);
  assert.equal(api.readProjectionCallback(() => [null]), -1);
  assert.throws(() => api.readProjectionCallback(() => [{value: 1}]), TypeError);
  assert.equal(api.callReference(value => {assert.equal(value, box); return value;}, box), box);
  assert.equal(api.callReference(value => {assert.equal(value, null); return null;}, null), null);
  assert.throws(() => api.callReference(() => ({value: 11}), null), TypeError);

  let traps = 0;
  const hostile = new Proxy({}, {
    get() {traps++; throw Error('opaque property');},
    getPrototypeOf() {traps++; throw Error('opaque prototype');},
  });
  const revoked = Proxy.revocable({}, {}); revoked.revoke();
  for (const value of [undefined, null, 1.5, 1n << 100n, Symbol('payload'), hostile,
    revoked.proxy, () => 1, Promise.resolve(1), {then() {throw Error('opaque then');}}]) {
    assert.equal(api.callPayload(argument => {assert.equal(argument, value); return argument;}, value), value);
  }
  assert.equal(traps, 0);
}

async function payloadResources(api) {
  let closing, resource;
  assert.equal(api.callNewResource(value => {
    resource = value; assert(value instanceof api.CallbackResource);
    assert.equal(value.id, 901); closing = value.close();
    assert.equal(api.callbackCleanups(901), 0);
    return value;
  }, 901), 901);
  await closing; assert.equal(api.callbackCleanups(901), 1);
  assert.throws(() => resource.apply(value => value));
  let complete;
  const work = api.callAsyncNewResource(value => {
    resource = value; closing = value.close();
    return new Promise(resolve => {complete = () => resolve(value);});
  }, 902);
  for (let i = 0; i < 3; i++) {await turn(); global.gc();}
  assert.equal(api.callbackCleanups(902), 0);
  complete(); assert.equal(await work, 902);
  await closing; assert.equal(api.callbackCleanups(902), 1);
  const reason = {callbackResource: true};
  exact(() => api.callNewResource(value => {
    closing = value.close(); assert.equal(api.callbackCleanups(903), 0); throw reason;
  }, 903), reason);
  await closing; assert.equal(api.callbackCleanups(903), 1);
  api.startResourceCallback(value => {
    closing = value.close();
    return new Promise(resolve => {complete = resolve;});
  }, 904);
  for (let i = 0; i < 3; i++) {await turn(); global.gc();}
  assert.equal(api.callbackCleanups(904), 0, 'an unawaited accepted callback keeps its resource operation');
  complete(); await closing; assert.equal(api.callbackCleanups(904), 1);
  const nested = new api.CallbackResource(905);
  const row = {values: new Map(), payloads: {}, references: [null], resource: nested};
  const copied = api.callContainers(value => {
    assert.equal(value.resource, nested); closing = nested.close();
    assert.equal(api.callbackCleanups(905), 0); return value;
  }, row);
  assert.equal(copied.resource, nested); await closing;
  assert.equal(api.callbackCleanups(905), 1);
  const asyncNested = new api.CallbackResource(906);
  const asynchronous = api.callAsyncContainers(async value => {
    assert.equal(value.resource, asyncNested); closing = asyncNested.close();
    await turn(); assert.equal(api.callbackCleanups(906), 0); return value;
  }, {...row, resource: asyncNested});
  assert.equal((await asynchronous).resource, asyncNested); await closing;
  assert.equal(api.callbackCleanups(906), 1);
  assert.deepEqual(api.callOptionalModels(function(options) {
    if (arguments.length === 0) return 0;
    if (options.resource === null && options.value === null) return 1;
    if (Object.hasOwn(options, 'value')) {
      assert.deepEqual(options.value, {value: 1, step: 7}); return 2;
    }
    assert.equal(options.resource.id, 907);
    closing = options.resource.close();
    assert.equal(api.callbackCleanups(907), 0);
    return 907;
  }, 907), [0, 1, 2, 907]);
  await closing; assert.equal(api.callbackCleanups(907), 1);
}

function failedCallbackPayload(api) {
  let payload = {failedCallback: true};
  const weak = new WeakRef(payload);
  assert.throws(() => api.rejectCallbackPayload(() => ({$1: payload, $2: {value: -1}})), /callback value constructor rejected/);
  payload = null;
  return weak;
}

async function retainedPayloads(api) {
  const failed = failedCallbackPayload(api);
  for (let i = 0; i < 60 && failed.deref() !== undefined; i++) {await turn(); global.gc();}
  assert.equal(failed.deref(), undefined, 'failed callback result releases opaque roots without Dart pressure');
  const box = new api.CallbackPayloadBox();
  let payload = {retainedCallback: true}; const weak = new WeakRef(payload);
  assert.equal(box.remember(value => value, payload), payload); payload = null;
  await turn(); global.gc(); await turn();
  assert(weak.deref()); assert.equal(box.saved(), weak.deref());
  assert.equal(box.invoke(weak.deref()), weak.deref());
  assert.throws(() => api.rejectCallbackPayload(() => ({$1: box.saved(), $2: {value: -1}})), /callback value constructor rejected/);
  await turn(); global.gc(); await turn();
  assert(weak.deref()); assert.equal(box.saved(), weak.deref(), 'failed conversion preserves a previously retained payload');
  box.clear(); await collect(api, () => weak.deref() === undefined, 'cleared callback payload');
}

function binaryValues(api) {
  const input = new Uint8Array([90, 1, 2, 91]).subarray(1, 3);
  let argument;
  const result = api.callBytes(value => {
    argument = value;
    assert.notEqual(value, input);
    assert.notEqual(value.buffer, input.buffer);
    assert.equal(value.byteOffset, 0);
    assert.equal(value.buffer.byteLength, 2);
    value[0] = 5;
    return value;
  }, input);
  assert.deepEqual([...input], [1, 2]);
  assert.deepEqual([...argument], [5, 2], 'Dart input/result mutations cannot change a callback snapshot');
  assert.deepEqual([...result], [6, 2]);
  assert.notEqual(result.buffer, argument.buffer);
  argument[1] = 8; assert.equal(result[1], 2);

  const raw = new Uint8Array([3, 4]).buffer;
  let bufferArgument;
  const bufferResult = api.callBuffer(value => {
    bufferArgument = value;
    assert.notEqual(value, raw);
    new Uint8Array(value)[0] = 7;
    return value;
  }, raw);
  assert.deepEqual([...new Uint8Array(raw)], [3, 4]);
  assert.deepEqual([...new Uint8Array(bufferArgument)], [7, 4]);
  assert.deepEqual([...new Uint8Array(bufferResult)], [8, 4]);
  assert.notEqual(bufferResult, bufferArgument);

  const shared = new Uint8Array([9, 10, 11]).subarray(1, 2);
  assert.equal(api.callShared(value => {
    assert.equal(value, shared); value[0] = 20; return value;
  }, shared), shared);
  assert.equal(shared[0], 21, 'SharedBytes mutations remain live in Dart and JS');
  assert.equal(api.callShared(value => { assert.equal(value, null); return null; }, null), null);
  const row = {bytes: [input, null, input], buffer: raw, shared};
  let returned;
  const copied = api.callBinaryRecord(value => {
    assert.notEqual(value, row);
    assert.notEqual(value.bytes, row.bytes);
    assert.notEqual(value.bytes[0].buffer, value.bytes[2].buffer);
    assert.equal(value.bytes[1], null);
    assert.equal(value.shared, shared);
    value.bytes[0][0] = 30; value.shared[0] = 31;
    returned = value;
    return value;
  }, row);
  assert.deepEqual([...input], [1, 2]); assert.equal(shared[0], 31);
  assert.notEqual(copied.bytes[0].buffer, returned.bytes[0].buffer);
  assert.notEqual(copied.buffer, returned.buffer);
  assert.equal(copied.shared, shared);
  returned.bytes[0][0] = 40; assert.equal(copied.bytes[0][0], 30);
  const empty = {bytes: [null], buffer: null, shared: null};
  assert.deepEqual(api.callBinaryRecord(value => value, empty), empty);
  api.clearBinaryCallback();

  const identity = value => value;
  assert.equal(api.binaryCallbackPolicies(identity, identity, identity, identity), true);
  const foreign = runInNewContext('new Uint8Array([7, 8])');
  assert.deepEqual([...api.callBytes(() => foreign, input)], [8, 8]);
  assert.equal(api.callShared(() => foreign, null), foreign);
  assert.equal(api.callShared(identity, Buffer.from([1]))[0], 2);
  for (const value of [undefined, null, [], new Uint16Array(1), new DataView(new ArrayBuffer(1)),
    new Uint8Array(new SharedArrayBuffer(1))]) {
    assert.throws(() => api.callBytes(() => value, input), TypeError);
  }
  for (const value of [undefined, {}, new Uint8Array(1), new SharedArrayBuffer(1)]) {
    assert.throws(() => api.callBuffer(() => value, raw), TypeError);
  }
  assert.throws(() => api.callShared(() => undefined, null), TypeError);
  assert.throws(() => api.callShared(() => new Uint8Array(new SharedArrayBuffer(1)), null), TypeError);
  const detached = new Uint8Array([1]);
  structuredClone(detached.buffer, {transfer: [detached.buffer]});
  assert.throws(() => api.callBytes(() => detached, input), TypeError);
  assert.throws(() => api.callBuffer(() => detached.buffer, raw), TypeError);
  assert.throws(() => api.callShared(() => detached, null), TypeError);
  const live = new Uint8Array([1]);
  assert.throws(() => api.callShared(value => {
    structuredClone(value.buffer, {transfer: [value.buffer]}); return null;
  }, live), TypeError);
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
  optionalArguments(api);
}

function optionalArguments(api) {
  let seen = [];
  assert.deepEqual(api.callOptionalPositionals(function(value = 7) {
    seen.push(Array.from(arguments)); return value;
  }), [7, 3]);
  assert.deepEqual(seen, [[], [3]], 'omission lets the JS callback apply its own default');
  seen = [];
  assert.deepEqual(api.callNullablePositionals(function(value = 7) {
    seen.push(Array.from(arguments)); return value;
  }), [7, null, 4]);
  assert.deepEqual(seen, [[], [null], [4]], 'explicit null never applies a JS default');
  const fallback = {fallback: true}; seen = [];
  const opaque = api.callOpaquePositionals(function(value = fallback) {
    seen.push(Array.from(arguments)); return value;
  }, undefined);
  assert.equal(opaque[0], fallback); assert.equal(opaque[1], null); assert.equal(opaque[2], fallback);
  assert.deepEqual(seen, [[], [null], [undefined]], 'present opaque undefined keeps its argument slot');
  seen = [];
  assert.deepEqual(api.callOptionalNames(function(options) {
    seen.push(arguments.length === 0 ? [] : [{...options}]);
    if (arguments.length === 0) return 7;
    assert.equal(Object.getPrototypeOf(options), null);
    return Object.values(options).reduce((sum, value) => sum + value, 0);
  }), [7, 1, 27]);
  assert.deepEqual(seen, [[], [{callback: 1}], [{operation: 2, arguments: 3, value: 4, env: 5, adapter: 6, state: 7}]]);
  assert.deepEqual(api.callMixedNames(function(value, options) {
    assert.equal(arguments.length, 2);
    assert.equal(Object.getPrototypeOf(options), null);
    assert.equal(Object.getOwnPropertyDescriptor(options, 'constructor').value, 4);
    return value + options.operation + options.constructor + (options.callback ?? 0);
  }), [7, 10]);
  assert.equal(api.callRequiredNames(function(options) {
    assert.equal(arguments.length, 1);
    assert.equal(Object.getOwnPropertyDescriptor(options, 'constructor').value, 6);
    return options.constructor;
  }), 6);
  const same = () => 0;
  assert.equal(api.callbackParameterPolicies(same, same, same, same, same), true,
    'positional names share adapters; parameter kinds and named keys do not');
  assert.throws(() => api.callOptionalPositionals(() => null), TypeError);
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

function savedBinaryCallback(api) {
  const callback = value => {
    if (value.shared !== null) value.shared[0]++;
    return value;
  };
  api.callBinaryRecord(callback, {bytes: [new Uint8Array([1])], buffer: null, shared: null});
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
  await asyncBinaryValues(api);
  await asyncPayloadValues(api);
  await asyncOptionalArguments(api);
}

async function asyncOptionalArguments(api) {
  const seen = [];
  assert.deepEqual(await api.callAsyncOptionalPositionals(async function(value = 7) {
    seen.push(Array.from(arguments)); await turn(); return value;
  }), [7, 5]);
  assert.deepEqual(seen, [[], [5]]);
  const fallback = {asyncFallback: true}, named = [];
  const result = await api.callAsyncOptionalNames(async function(options = {}) {
    named.push({argc: arguments.length, present: Object.hasOwn(options, 'value'), value: options.value});
    const {value = fallback} = options;
    await turn(); return value;
  }, undefined);
  assert.equal(result[0], fallback); assert.equal(result[1], null); assert.equal(result[2], fallback);
  assert.deepEqual(named, [
    {argc: 0, present: false, value: undefined},
    {argc: 1, present: true, value: null},
    {argc: 1, present: true, value: undefined},
  ]);
  await assert.rejects(api.callAsyncOptionalPositionals(() => 7), TypeError);
}

async function asyncPayloadValues(api) {
  const box = new api.CallbackBox(() => 17), payload = {asyncPayload: true};
  const row = {values: new Map([['one', [{value: 2}, null]]]), payloads: {one: payload, absent: undefined}, references: [box, null], resource: null};
  const result = await api.callAsyncContainers(async value => {
    await turn(); global.gc();
    assert.equal(value.references[0], box); assert.equal(value.payloads.one, payload);
    return {...value, values: new Map([['two', [{value: 4}, null]]])};
  }, row);
  assert.deepEqual(result.values.get('two'), [{value: 4, step: 7}, null]);
  assert.equal(result.payloads.one, payload); assert.equal(result.references[0], box);
  assert.notEqual(result.values, row.values);
  for (const value of [payload, undefined, null, Symbol('async payload')]) {
    assert.equal(await api.callAsyncPayload(async argument => {assert.equal(argument, value); return argument;}, value), value);
  }
  await assert.rejects(api.callAsyncContainers(async value => ({...value, values: new Map([['bad', [{value: -1}]]])}), row), /callback value constructor rejected/);
}

async function asyncBinaryValues(api) {
  const input = new Uint8Array([1, 2]);
  let argument, fulfill;
  const pending = api.callAsyncBytes(value => {
    argument = value;
    return new Promise(resolve => { fulfill = resolve; });
  }, input);
  input[0] = 3;
  await turn(); global.gc();
  assert.deepEqual([...argument], [1, 2]);
  const returned = new Uint8Array([7, 8]); fulfill(returned);
  const result = await pending;
  assert.deepEqual([...result], [8, 8]);
  assert.deepEqual([...argument], [1, 2]);
  assert.deepEqual([...returned], [7, 8]);
  assert.notEqual(result.buffer, returned.buffer);
  returned[1] = 9; assert.equal(result[1], 8);
  assert.equal(await api.callAsyncBytes(async value => { assert.equal(value, null); return null; }, null), null);
  await assert.rejects(api.callAsyncBytes(async () => new Uint16Array(1), null), TypeError);
  const detachedBytes = new Uint8Array([1]);
  const detachedSnapshot = api.callAsyncBytes(() => Promise.resolve(detachedBytes), null);
  structuredClone(detachedBytes.buffer, {transfer: [detachedBytes.buffer]});
  await assert.rejects(detachedSnapshot, TypeError);

  const shared = new Uint8Array([2]), sharedResult = new Uint8Array([5]);
  let complete;
  const sharedWork = api.callAsyncShared(value => {
    assert.equal(value, shared);
    return new Promise(resolve => { complete = resolve; });
  }, shared);
  shared[0] = 3;
  for (let i = 0; i < 3; i++) { await turn(); global.gc(); }
  complete(sharedResult);
  assert.equal(await sharedWork, sharedResult);
  assert.equal(shared[0], 4); assert.equal(sharedResult[0], 6);
  assert.equal(await api.callAsyncShared(async value => { assert.equal(value, null); return null; }, null), null);
  await assert.rejects(api.callAsyncShared(async () => new Uint8Array(new SharedArrayBuffer(1)), null), TypeError);
  const detachedShared = new Uint8Array([1]);
  const detachedResult = api.callAsyncShared(() => Promise.resolve(detachedShared), null);
  structuredClone(detachedShared.buffer, {transfer: [detachedShared.buffer]});
  await assert.rejects(detachedResult, TypeError);
  const retained = new Uint8Array([1]);
  let release;
  const detachedInput = api.callAsyncShared(() => new Promise(resolve => { release = resolve; }), retained);
  structuredClone(retained.buffer, {transfer: [retained.buffer]}); release(null);
  await assert.rejects(detachedInput, TypeError);
  const resizable = new ArrayBuffer(4, {maxByteLength: 8});
  const fixed = new Uint8Array(resizable, 2, 2);
  const resizedInput = api.callAsyncShared(() => new Promise(resolve => { release = resolve; }), fixed);
  resizable.resize(1); release(null);
  await assert.rejects(resizedInput, TypeError);

  const row = {bytes: [new Uint8Array([1]), null], buffer: new Uint8Array([2]).buffer, shared: new Uint8Array([3])};
  let callbackRow;
  const copied = await api.callAsyncBinaryRecord(async value => {
    callbackRow = value;
    await turn();
    value.bytes[0][0] = 4; value.shared[0] = 5;
    return value;
  }, row);
  assert.equal(row.bytes[0][0], 1);
  assert.equal(copied.bytes[0][0], 4);
  assert.notEqual(copied.bytes[0].buffer, callbackRow.bytes[0].buffer);
  assert.notEqual(copied.buffer, callbackRow.buffer);
  assert.equal(copied.shared, row.shared); assert.equal(row.shared[0], 5);
  const empty = {bytes: [null], buffer: null, shared: null};
  assert.deepEqual(await api.callAsyncBinaryRecord(async value => value, empty), empty);
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

function handleValues(api) {
  const original = [1], fresh = [2];
  assert.equal(api.callHandle(value => {
    assert.equal(value, original); value.push(3); return fresh;
  }, original), fresh);
  assert.deepEqual(original, [1, 3]); fresh[0] = 4;
  assert.equal(api.readCallbackHandle(0), 4, 'Dart retains the new callback result adapter');
  const identity = value => value;
  assert.equal(api.callHandle(identity, original), original);
  assert.equal(api.sameHandleSignature(identity), true);
  assert.equal(api.sameWideHandleSignature(identity), false);
  assert.equal(api.sameOpaqueHandleSignature(identity), false);
  const wide = [9007199254740993n];
  assert.equal(api.callWideHandle(identity, wide), wide);
  assert.throws(() => api.callWideHandle(() => [1], wide), TypeError);

  const map = new Map([['key', null]]), record = {arrays: [original, null], map};
  const output = api.callHandles(value => {
    assert.notEqual(value, record); assert.notEqual(value.arrays, record.arrays);
    assert.equal(value.arrays[0], original); assert.equal(value.arrays[1], null);
    assert.equal(value.map, map); value.map.set('key', 8);
    return {arrays: [fresh, null], map: value.map};
  }, record);
  assert.equal(output.arrays[0], fresh); assert.equal(output.arrays[1], null);
  assert.equal(output.map, map); assert.equal(map.get('key'), 8);
  assert.equal(api.callNullableHandle(value => {assert.equal(value, null); return null;}, null), null);
  assert.equal(api.callNullableHandle(identity, original), original);
  assert.throws(() => api.callNullableHandle(() => undefined, null), TypeError);
  assert.throws(() => api.callHandle(() => ({}), original), TypeError);
  assert.throws(() => api.callHandles(() => ({arrays: [undefined], map}), record), TypeError);

  const payload = {then() {throw Error('opaque payload then');}}, raw = [undefined, payload];
  const payloadMap = new Map([[payload, undefined]]), outer = {arrays: [raw], map: payloadMap};
  const opaque = api.callPayloadHandles(value => {
    assert.notEqual(value, outer); assert.notEqual(value.arrays, outer.arrays);
    assert.equal(value.arrays[0], raw); assert.equal(value.map, payloadMap);
    value.arrays[0].push(payload); value.map.set(undefined, payload); return value;
  }, outer);
  assert.notEqual(opaque, outer); assert.equal(opaque.arrays[0], raw); assert.equal(raw[2], payload);
  assert.equal(opaque.map, payloadMap); assert.equal(payloadMap.get(undefined), payload);
  for (const error of [{handle: true}, Symbol('handle'), undefined]) {
    exact(() => api.callHandle(() => {throw error;}, original), error);
    const lazy = []; Object.defineProperty(lazy, '0', {get() {throw error;}});
    assert.equal(api.callHandle(() => lazy, original), lazy);
    exact(() => api.readCallbackHandle(0), error);
  }
  api.callHandle(identity, original);
  let invoked = 0;
  for (const fake of [false, true]) {
    assert.throws(() => api.callbackHandleOrder(() => {invoked++; return 1n;}, fake, false), TypeError);
    assert.throws(() => api.callbackHandleOrder(() => {invoked++; return 1n;}, fake, true),
      error => !(error instanceof TypeError) && /callback argument getter/.test(error.message));
  }
  assert.equal(invoked, 0, 'Dart snapshots every callback argument before handle validation');
  api.clearCallbackHandle();
}

async function asyncHandles(api) {
  let complete, input = [7];
  const weak = new WeakRef(input);
  let callback = value => {
    assert.equal(value, input);
    return new Promise(resolve => {complete = resolve;});
  };
  const pending = api.callAsyncHandle(callback, input);
  await until(() => complete !== undefined, 'handle callback starts');
  input = undefined; callback = undefined;
  for (let round = 0; round < 4; round++) {
    await turn(); global.gc(); api.callbackPressure(round); await turn();
    assert(weak.deref(), 'Dart keeps its handle input while the callback Promise is pending');
  }
  const retainedInput = weak.deref(); assert(retainedInput);
  const fresh = [9]; complete(fresh); complete = undefined;
  assert.equal(await pending, fresh); assert.equal(retainedInput[0], 8);
  fresh[0] = 10; assert.equal(api.readCallbackHandle(0), 10);
  for (const error of [{asyncHandle: true}, Symbol('async-handle'), undefined]) {
    await exactRejection(api.callAsyncHandle(() => Promise.reject(error), [1]), error);
    await exactRejection(api.callAsyncHandle(() => {throw error;}, [1]), error);
  }
  await assert.rejects(api.callAsyncHandle(() => Promise.resolve({}), [1]), TypeError);
  await assert.rejects(api.callAsyncHandle(value => value, [1]), TypeError);
  api.clearCallbackHandle();
}

async function foreignOwner(api) {
  const other = await import('@napi/callback-external');
  const foreign = new other.CallbackBox(() => 1);
  assert.throws(() => api.callReference(value => value, foreign), TypeError);
  assert.throws(() => api.callReference(() => foreign, null), TypeError);
  const local = new api.CallbackBox(() => 2);
  assert.throws(() => other.callReference(() => local, null), TypeError);
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
      const binary = savedBinaryCallback(api);
      await turn(); global.gc(); api.callbackPressure(1); await turn();
      assert(binary.deref());
      const shared = new Uint8Array([2]);
      const row = api.invokeBinaryRecord({bytes: [new Uint8Array([1])], buffer: null, shared});
      assert.equal(row.shared, shared); assert.equal(shared[0], 3);
      api.clearBinaryCallback();
      await collect(api, () => binary.deref() === undefined, 'cleared binary callback');
      await retainedPayloads(api);
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
    case 'resources': await resources(api); await payloadResources(api); break;
    case 'identity': await identity(api); break;
    case 'async-values': await asyncValues(api); break;
    case 'async-validation': await asyncValidation(api); break;
    case 'async-errors': await asyncErrors(api); break;
    case 'async-retention': await asyncRetention(api); break;
    case 'async-resources': await asyncResources(api); break;
    case 'js-handles': handleValues(api); break;
    case 'async-handles': await asyncHandles(api); break;
    case 'foreign-owner': await foreignOwner(api); break;
    case 'pending-natural-exit': {
      api.registerAsyncCallback(() => new Promise(() => {}));
      api.invokeAsyncRegistered(0, 1);
      break;
    }
    case 'queued-teardown': await worker(false, true); break;
    case 'external': {
      const external = await import('@napi/callback-external');
      assert.deepEqual(Object.keys(external), [
        'CallbackBox', 'CallbackPayloadBox', 'CallbackResource',
        'binaryCallbackPolicies', 'callAsyncBinaryRecord', 'callAsyncBytes', 'callAsyncHandle',
        'callAsyncShared', 'callBinaryRecord', 'callBuffer', 'callBytes', 'callHandle', 'callHandles',
        'callNullableHandle', 'callPayloadHandles', 'callShared', 'callWideHandle',
        'callbackHandleOrder', 'callbackPressure', 'clearBinaryCallback', 'clearCallbackHandle',
        'invokeBinaryRecord', 'plainAsyncCallback', 'plainCallback', 'readCallbackHandle', 'sameHandleSignature',
        'sameOpaqueHandleSignature', 'sameWideHandleSignature',
        'callContainers', 'callAsyncContainers', 'callKeyMap', 'callNormalized',
        'callProjection', 'readProjectionCallback', 'callReference', 'callNewResource',
        'callAsyncNewResource', 'callPayload', 'callAsyncPayload', 'rejectCallbackPayload', 'callbackCleanups',
        'startResourceCallback',
        'callOptionalPositionals', 'callNullablePositionals', 'callOpaquePositionals',
        'callOptionalNames', 'callMixedNames', 'callRequiredNames',
        'callAsyncOptionalPositionals', 'callAsyncOptionalNames',
        'callOptionalModels', 'callbackParameterPolicies',
      ].sort());
      assert.equal(external.plainCallback(n => n + 1, 3), 4);
      assert.throws(() => external.plainCallback(), TypeError);
      assert.throws(() => external.plainCallback(n => 'bad', 1), TypeError);
      const error = {external: true};
      exact(() => external.plainCallback(() => { throw error; }, 1), error);
      assert.equal(await external.plainAsyncCallback(async n => n + 1, 3), 4);
      await exactRejection(external.plainAsyncCallback(() => Promise.reject(error), 1), error);
      await assert.rejects(external.plainAsyncCallback(n => n, 1), TypeError);
      handleValues(external); await asyncHandles(external);
      binaryValues(external); await asyncBinaryValues(external);
      payloadValues(external); await asyncPayloadValues(external);
      optionalArguments(external); await asyncOptionalArguments(external);
      await payloadResources(external); await retainedPayloads(external);
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
  binaryValues(api); await asyncBinaryValues(api);
  payloadValues(api); await asyncPayloadValues(api); await payloadResources(api);
  optionalArguments(api); await asyncOptionalArguments(api);
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
  throw Error('Pass one callback scenario; package:test owns scenario execution.');
}
