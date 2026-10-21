import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {cpSync, mkdtempSync} from 'node:fs';
import {basename, dirname, join} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
import {runInNewContext} from 'node:vm';
import {Worker, isMainThread, parentPort, workerData} from 'node:worker_threads';

import {hierarchy, hierarchyRetention} from './opaque_hierarchy.mjs';

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
  const external = await import('@napi/opaque-external');
  let traps = 0;
  const hostile = new Proxy({}, {
    get() { traps++; throw Error('unexpected payload get'); },
    getPrototypeOf() { traps++; throw Error('unexpected payload prototype'); },
    ownKeys() { traps++; throw Error('unexpected payload keys'); },
  });
  const revoked = Proxy.revocable({}, {});
  revoked.revoke();
  const hostileFunction = new Proxy(() => {}, {
    get() { traps++; throw Error('unexpected function payload get'); },
    getPrototypeOf() { traps++; throw Error('unexpected function payload prototype'); },
    ownKeys() { traps++; throw Error('unexpected function payload keys'); },
    apply() { traps++; throw Error('unexpected function payload call'); },
    construct() { traps++; throw Error('unexpected function payload construction'); },
  });
  const revokedFunction = Proxy.revocable(() => {}, {});
  revokedFunction.revoke();
  const thenable = Object.defineProperty({}, 'then', {
    get() { traps++; throw Error('unexpected payload then'); },
  });
  const router = new api.Router();
  const nestedStores = [new api.NestedStore(), new external.NestedStore()];
  const payloads = [
    {x: 1}, () => 19, Symbol('local'), Symbol.for('opaque'),
    (1n << 100n) + 3n, -(1n << 100n), null, undefined, -0, NaN,
    Infinity, -Infinity, true, false, 'a\ud800b\udfff', new Uint8Array([0, 255]),
    Buffer.from([3, 7]), [1, {x: 2}], Object.freeze({frozen: true}),
    hostile, revoked.proxy, hostileFunction, revokedFunction.proxy,
    thenable, Promise.resolve(42),
    runInNewContext('({foreign: true})'), 0,
  ];
  assert.equal(payloads.length, 27);
  for (const value of payloads) {
    for (const nested of nestedStores) {
      const input = [[value, value]];
      const lists = nested.lists(input);
      assert.notEqual(lists, input);
      assert.notEqual(lists[0], input[0]);
      assert(Object.is(lists[0][0], value));
      assert(Object.is(lists[0][1], value));
      assert(Object.is(nested.dictionary({value}).value, value));
      assert(Object.is(nested.map(new Map([['value', [value]]])).get('value')[0], value));
      const record = nested.record({value, rest: [value]});
      assert(Object.is(record.value, value));
      assert(Object.is(record.rest[0], value));
      assert(Object.is((await nested.futureList([value]))[0], value));
    }
    assert(Object.is(api.identity(value), value));
    assert(Object.is(api.optional(value), value));
    for (const entry of [api, external]) {
      const input = {value, optional: value, items: [value]};
      const copied = entry.opaqueValueEcho(input);
      assert.notEqual(copied, input);
      assert.notEqual(copied.items, input.items);
      assert(Object.is(copied.value, value));
      assert(Object.is(copied.optional, value));
      assert(Object.is(copied.items[0], value));
      const callback = entry.opaqueValueCallback(input, argument => {
        assert.notEqual(argument, input);
        assert(Object.is(argument.value, value));
        assert(Object.is(argument.optional, value));
        assert(Object.is(argument.items[0], value));
        return argument;
      });
      assert(Object.is(callback.value, value));
      assert(Object.is(callback.optional, value));
      assert(Object.is(callback.items[0], value));
      assert(Object.is(entry.named(7, {first: value}), value));
      assert(Object.is(entry.named(0, {second: value}), value));
      assert(Object.is(entry.mixedRequired({first: value}), value));
      const store = new entry.NamedStore({first: value, second: value});
      assert(Object.is(store.first, value));
      assert(Object.is(store.second, value));
      assert(Object.is(store.select(0, {second: value}), value));
      store.clear();
    }
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
  for (const entry of [api, external]) {
    const defaults = entry.opaqueValueEcho({value: undefined});
    assert.equal(defaults.value, undefined);
    assert.equal(defaults.optional, null);
    assert.deepEqual(defaults.items, []);
    const undefinedDefault = entry.opaqueValueEcho({value: null, optional: undefined, items: undefined});
    assert.equal(undefinedDefault.optional, undefined);
    assert.deepEqual(undefinedDefault.items, []);
    assert.throws(() => entry.opaqueValueEcho({}), TypeError);
    assert.throws(() => entry.opaqueValueEcho({value: 1, get optional() { assert.fail('accessor invoked'); }}), TypeError);
  }
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

async function methods(api) {
  const external = await import('@napi/opaque-external');
  for (const entry of [api, external]) {
    const owner = {owner: true};
    const box = new entry.MethodBox(owner);
    const revoked = Proxy.revocable({}, {});
    revoked.revoke();
    let traps = 0;
    const hostile = new Proxy(() => {}, {
      get() { traps++; throw Error('method payload inspection'); },
      getPrototypeOf() { traps++; throw Error('method payload prototype'); },
      apply() { traps++; throw Error('method payload call'); },
    });
    const values = [undefined, null, {payload: true}, Symbol('method'), 1n << 100n,
      -0, NaN, hostile, revoked.proxy, runInNewContext('({foreign: true})')];
    for (const value of values) {
      assert(Object.is(box.echo(value), value));
      assert(Object.is(entry.MethodBox.staticEcho(value), value));
      assert(Object.is(box.optional(value), value));
      assert(Object.is(box.named(0, {second: value}), value));
      assert(Object.is(box.requiredNamed({value}), value));
      assert(Object.is(new entry.MethodShadow().echo(value), value));
      assert(Object.is(new entry.MethodA().echo(value), value));
      assert(Object.is(new entry.MethodB().echo(value), value));
      assert.deepEqual(box.both(value), {$1: owner, $2: value});
      const wrapped = box.wrap(value);
      assert(Object.is(wrapped.get('initial'), value));
      assert.equal(box.references([wrapped])[0], wrapped);
      assert(Object.is(box.list([value])[0], value));
      assert(Object.is(box.dictionary({value}).value, value));
      const array = [value], map = new Map([[owner, value]]);
      assert.equal(box.array(array), array);
      assert.equal(box.map(map), map);
      const iterator = box.events(value);
      assert(Object.is((await iterator.next()).value, value));
      await iterator.return();
    }
    assert.equal(traps, 0);
    assert.equal(box.unused(), 7);
    assert.equal(box.optional(), null);
    assert.equal(box.named(7), null);
    assert.equal(box.named(0, {first: 1, second: 2, choose: 0}), 1);
    assert.throws(() => box.echo(), TypeError);
    assert.throws(() => box.requiredNamed({}), TypeError);
    assert.equal(box.optional(1, 2), 1, 'extra JS arguments retain the ordinary call contract');
    assert.throws(() => entry.MethodBox.prototype.echo.call({}, 1), TypeError);
    assert.throws(() => new box.echo(1), TypeError);
    const calls = entry.opaqueCalls();
    assert.throws(() => box.checked([{value: {}, count: 'bad'}], 1), TypeError);
    assert.throws(() => box.checked([{value: {}, count: 1}], 'bad'), TypeError);
    assert.equal(entry.opaqueCalls(), calls);
    const payload = {kept: true};
    assert.throws(() => box.saveThrow(payload), /saved method input/);
    assert.equal(box.saved(), payload, 'business throw must not revoke a stored carrier');
    box.clear();
    for (const error of [undefined, null, Symbol('exact method error')]) {
      assert.throws(() => box.callback(payload, () => { throw error; }), e => Object.is(e, error));
    }
    assert.equal(box.callback(payload, count => {
      assert.equal(count, 7);
      assert.equal(box.echo(payload), payload);
    }), payload);
    assert.equal(await box.later({then(resolve) { resolve(29); }}), 29);
    const inner = {value: (resolve) => resolve(11)};
    assert.equal((await box.futureDictionary({then: resolve => resolve(inner)})), inner);
    assert.deepEqual(new entry.MethodInt(9).pair(payload), {$1: 9, $2: payload});
    const composite = entry.methodComposite();
    assert.equal(composite instanceof entry.MethodA, false);
    assert.equal(composite instanceof entry.MethodB, false);
    assert.equal(composite.echo(payload), payload);
    assert.equal(entry.MethodA.prototype.echo.call(composite, payload), payload);
    assert.equal(entry.MethodB.prototype.echo.call(composite, payload), payload);
    assert.throws(() => entry.methodDefaultConflict(), TypeError);
  }
  const box = new api.MethodBox(null);
  const foreign = new external.Router();
  assert.equal(box.echo(foreign), foreign);
  assert.throws(() => box.references([foreign]), TypeError);
}

async function inheritedMethods(api) {
  for (const entry of [api, await import('@napi/opaque-external')]) {
    const owner = {owner: true}, value = {value: true};
    const inherited = new entry.MethodInherited(owner);
    assert(inherited instanceof entry.MethodBox);
    assert.equal(inherited.echo(value), value);
    assert.equal(inherited.optional(), null);
    assert.equal(inherited.optional(undefined), undefined);
    assert.equal(entry.MethodBox.prototype.echo.call(inherited, value), value);
    assert.deepEqual(inherited.both(value), {$1: owner, $2: value});
    assert.equal(inherited.list([undefined, value])[1], value);
    assert.equal(inherited.dictionary({value}).value, value);
    const ref = new entry.Router();
    assert.equal(inherited.references([ref])[0], ref);
    const array = [value], map = new Map([[owner, value]]);
    assert.equal(inherited.array(array), array);
    assert.equal(inherited.map(map), map);
    assert.equal(await inherited.later({then(resolve) { resolve(value); }}), value);
    const events = inherited.events(value);
    assert.equal((await events.next()).value, value);
    await events.return();
    assert.throws(() => inherited.echo(), TypeError);
    assert.throws(() => entry.MethodBox.prototype.echo.call({}, value), TypeError);
    const override = new entry.MethodOverride(owner);
    assert.equal(override.echo(value), value);
    assert.equal(override.named(9, {first: value}), value);
    assert.equal(override.named(7, {first: value}), null);
    assert.equal(entry.MethodBox.prototype.named.call(override, 7, {first: value}), value);
    const interfaced = new entry.MethodInterface();
    assert.equal(interfaced instanceof entry.MethodContract, false);
    assert.deepEqual(entry.MethodContract.prototype.combine.call(interfaced, owner, value),
      {$1: owner, $2: value, $3: 7});
    assert.deepEqual(interfaced.combine(owner, value), {$1: owner, $2: value, $3: 7},
      'the selected contract supplies its default, not the private mixin default');
    assert.deepEqual(interfaced.combine(undefined, null, 13), {$1: undefined, $2: null, $3: 13});
    const pair = new entry.MethodPairChild();
    assert(pair instanceof entry.MethodPair);
    assert.deepEqual(pair.combine(owner, value, undefined), {$1: owner, $2: value, $3: undefined});
    assert.deepEqual(entry.MethodPair.prototype.combine.call(pair, owner, value, null),
      {$1: owner, $2: value, $3: null});
    assert.deepEqual(new entry.MethodIntChild(17).pair(value), {$1: 17, $2: value});
  }
}

async function methodRetention(api) {
  let pending;
  const held = (() => {
    const owner = {owner: true}, input = {input: true};
    pending = new api.MethodBox(owner).wait(input);
    return [new WeakRef(owner), new WeakRef(input)];
  })();
  await keep(api, () => held.every(ref => ref.deref()), 'method Future receiver and input');
  api.completeOpaque(17);
  assert.equal(await pending, 17);
  await collect(api, () => held.every(ref => !ref.deref()), 'settled method Future roots');
  let stream;
  const streamRoots = (() => {
    const owner = {streamOwner: true}, input = {streamInput: true};
    stream = new api.MethodBox(owner).hold(input);
    return [new WeakRef(owner), new WeakRef(input)];
  })();
  await keep(api, () => streamRoots.every(ref => ref.deref()), 'method Stream receiver and input');
  await stream.return();
  await collect(api, () => streamRoots.every(ref => !ref.deref()), 'cancelled method Stream roots');
  const box = new api.MethodBox(null);
  const failed = (() => {
    const value = {partial: true};
    assert.throws(() => box.checked([{value, count: 1}], 'invalid'), TypeError);
    return new WeakRef(value);
  })();
  await collect(api, () => !failed.deref(), 'rejected method argument carrier');
  const retained = (() => {
    const value = {saved: true};
    assert.throws(() => box.saveThrow(value), /saved method input/);
    return new WeakRef(value);
  })();
  await keep(api, () => retained.deref() === box.saved(), 'saved method input after throw');
  box.clear();
  await collect(api, () => !retained.deref(), 'cleared method input');
}

async function methodResources(api) {
  for (const entry of [api, await import('@napi/opaque-external')]) {
    for (const Session of [entry.MethodSession, entry.MethodInheritedSession]) {
      let cleanups = entry.methodCleanups();
      const resource = new Session();
      const pending = resource.pending({value: true});
      const closed = resource.close();
      assert.equal(resource.close(), closed);
      await turn();
      assert.equal(entry.methodCleanups(), cleanups);
      await assert.rejects(resource.pending({later: true}));
      entry.completeOpaque(31);
      assert.equal(await pending, 31);
      await closed;
      assert.equal(entry.methodCleanups(), ++cleanups);
      const streamed = new Session();
      const iterator = streamed.hold({stream: true});
      const streamClosed = streamed.close();
      await streamClosed;
      assert.equal((await iterator.next()).done, true);
      assert.equal(entry.methodCleanups(), ++cleanups);
      const adopted = new Session();
      let settle;
      const result = adopted.later({then(resolve) { settle = resolve; }});
      const adoptedClosed = adopted.close();
      for (let turnIndex = 0; turnIndex < 20 && !settle; turnIndex++) await turn();
      assert.equal(typeof settle, 'function');
      assert.equal(entry.methodCleanups(), cleanups, 'thenable settlement retains the operation');
      settle(53);
      assert.equal(await result, 53);
      await adoptedClosed;
      assert.equal(entry.methodCleanups(), ++cleanups);
    }
  }
}

async function nestedValues(api) {
  const store = new api.NestedStore();
  assert.deepEqual(store.nulls([null, undefined]), [false, false]);
  assert.deepEqual(store.withNull([undefined]), [null, undefined]);
  assert.throws(() => store.lists(), TypeError);
  assert.throws(() => store.lists(undefined), TypeError);
  assert.throws(() => store.lists([Array(1)]), TypeError);
  assert.throws(() => store.record({rest: []}), TypeError);
  assert.throws(() => store.record({value: 1, get rest() { throw Error('getter'); }}), TypeError);
  const reference = new api.NamedStore({first: undefined});
  const references = store.references([reference, reference]);
  assert.equal(references[0], reference);
  assert.equal(references[1], reference);
  assert.throws(() => store.references([{}]), TypeError);
  const pair = new api.OpaquePairChild('key', 7);
  assert.equal(api.nestedPairs([pair])[0], pair);
  assert.equal(api.nestedPairs([pair])[0].readSecond(), 7);
  const value = {saved: true};
  assert.throws(() => store.saveThrow([value]), /saved nested input/);
  assert.equal(store.values[0], value);
  assert.throws(() => store.badOutput([value]), RangeError);
  assert.equal(store.values[0], value, 'output failure must not release stored inputs');
  store.clear();
  const calls = api.opaqueCalls();
  assert.throws(() => store.checked([{value, count: 1}, {value, count: 'bad'}], 1), TypeError);
  assert.throws(() => store.checked([{value, count: 1}], 'bad'), TypeError);
  assert.equal(api.opaqueCalls(), calls);
  let invoked = 0;
  const then = (resolve, reject) => { invoked++; resolve(42); reject('late'); };
  assert.equal(await store.futureThen([then]), 42);
  assert.equal(await store.futureDictionary({then}), 42);
  assert.equal((await store.futureDictionary({value: then})).value, then);
  assert.equal((await store.futureList([then]))[0], then);
  const iterator = store.streamThen([then]);
  assert.equal((await iterator.next()).value.then, then);
  assert.equal((await iterator.next()).done, true);
  assert.equal(invoked, 2, 'nested values and Stream events never deep-await');
  for (const present of [false, true]) {
    const inner = present ? {then} : {value: then};
    const outer = resolve => resolve(inner);
    const expected = present ? 42 : inner;
    assert.equal(await store.futureDictionary({then: outer}), expected);
    assert.equal(await store.futureThen([outer]), expected);
    assert.equal(await (api.futureIdentity ?? api.plainFuture)({then: outer}), expected);
  }
  for (const reason of [null, undefined, Symbol('nested then')]) {
    await assert.rejects(store.futureThen([() => { throw reason; }]), error => Object.is(error, reason));
  }
}

async function nestedRetention(api) {
  const store = new api.NestedStore();
  const saved = (() => {
    const value = {saved: true};
    assert.throws(() => store.saveThrow([value]), /saved nested input/);
    return new WeakRef(value);
  })();
  await keep(api, () => saved.deref() !== undefined, 'saved nested input after throw');
  store.clear();
  await collect(api, () => saved.deref() === undefined, 'cleared nested input');
  const failed = (() => {
    const value = {failed: true};
    assert.throws(() => store.checked([{value, count: 1}], 'bad'), TypeError);
    assert.throws(() => store.checked([{value, count: 1}, {value, count: 'bad'}], 1), TypeError);
    return new WeakRef(value);
  })();
  await collect(api, () => failed.deref() === undefined, 'partial nested admission');
  let pending;
  const held = (() => {
    const value = {pending: true};
    pending = store.wait([value]);
    return new WeakRef(value);
  })();
  await keep(api, () => held.deref() !== undefined, 'pending nested Future input');
  api.completeOpaque(7);
  assert.equal(await pending, 7);
  await collect(api, () => held.deref() === undefined, 'completed nested Future input');
  let iterator;
  const streamed = (() => {
    const value = {stream: true};
    iterator = store.hold([value]);
    return new WeakRef(value);
  })();
  await keep(api, () => streamed.deref() !== undefined, 'unread Stream nested input');
  await iterator.return();
  await collect(api, () => streamed.deref() === undefined, 'returned Stream nested input');
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

async function namedPresence(api) {
  const store = new api.NamedStore();
  for (const args of [[], [undefined], [{}]]) {
    assert.equal(api.named(7, ...args), null);
    assert.equal(api.named(0, ...args), null);
    const empty = new api.NamedStore(...args);
    assert.equal(empty.first, null);
    assert.equal(empty.second, null);
    const marked = api.NamedStore.withMarker(9, ...args);
    assert.equal(marked.marker, 9);
    assert.equal(marked.first, null);
    assert.equal(marked.second, null);
    assert.equal(store.select(7, ...args), null);
    assert.equal(await genuine(() => api.futureNamed(0, ...args)), null);
    assert.equal(await genuine(() => store.futureSelect(7, ...args)), null);
  }
  assert.equal(api.named(7, {first: 'first', second: 'second', choose: undefined}), 'first');
  assert.equal(api.named(7, {first: 'first', second: 'second', choose: 0}), 'second');
  for (const value of [undefined, null]) {
    assert.equal(api.named(7, {first: value}), value);
    assert.equal(api.named(0, {second: value}), value);
    assert.equal(api.mixedRequired({first: value}), value);
    assert.equal(api.mixedRequired({first: 'required', second: value, choose: 0}), value);
    const initial = new api.NamedStore({first: value, second: value});
    const marked = api.NamedStore.withMarker(9, {first: value, second: value});
    for (const current of [initial, marked]) {
      assert.equal(current.first, value);
      assert.equal(current.second, value);
      assert.equal(current.select(7, {first: value}), value);
      assert.equal(current.select(0, {second: value}), value);
      assert.equal(await genuine(() => current.futureSelect(7, {first: value})), value);
      assert.equal(await genuine(() => current.futureSelect(0, {second: value})), value);
    }
    assert.equal(await genuine(() => api.futureNamed(7, {first: value})), value);
    assert.equal(await genuine(() => api.futureNamed(0, {second: value})), value);
  }
  const payload = {named: true};
  assert.equal(await genuine(() => api.futureNamed(7, {first: payload})), payload);
  assert.equal(await genuine(() => store.futureSelect(0, {second: payload})), payload);
  assert.equal(await genuine(() => api.futureNamed(0, {
    second: {then(resolve) { resolve(42); }},
  })), 42);
  assert.equal(api.mixedRequired({first: 'required', choose: 0}), null);

  const before = api.opaqueCalls();
  for (const call of [
    () => api.named(),
    () => api.named(undefined),
    () => api.named(7, null),
    () => api.named(7, {unknown: 1}),
    () => api.named(7, {choose: null}),
    () => api.mixedRequired(),
    () => api.mixedRequired(undefined),
    () => api.mixedRequired({}),
    () => api.mixedRequired({second: null}),
    () => api.mixedRequired(Object.assign(Object.create({first: 1}), {second: 2})),
    () => new api.NamedStore({unknown: 1}),
    () => api.NamedStore.withMarker(),
    () => api.NamedStore.withMarker(9, null),
    () => store.select(7, {choose: null}),
  ]) assert.throws(call, TypeError);
  await assert.rejects(genuine(() => api.futureNamed(7, {choose: null})), TypeError);
  await assert.rejects(genuine(() => store.futureSelect()), TypeError);
  let getterCalls = 0;
  for (const key of ['first', 'second']) {
    const options = Object.defineProperty({}, key, {get() { getterCalls++; return 1; }});
    assert.throws(() => api.named(7, options), TypeError);
    assert.throws(() => new api.NamedStore(options), TypeError);
    assert.throws(() => api.NamedStore.withMarker(9, options), TypeError);
    assert.throws(() => store.select(7, options), TypeError);
    await assert.rejects(genuine(() => api.futureNamed(7, options)), TypeError);
    await assert.rejects(genuine(() => store.futureSelect(7, options)), TypeError);
  }
  assert.equal(getterCalls, 0, 'named opaque accessors are rejected without invocation');
  for (const exact of [{reflection: true}, null, undefined]) {
    for (const trap of ['getPrototypeOf', 'ownKeys', 'getOwnPropertyDescriptor']) {
      const options = new Proxy({first: 1}, {[trap]() { throw exact; }});
      assert.throws(() => api.named(7, options), error => error === exact);
      await assert.rejects(genuine(() => api.futureNamed(7, options)), error => error === exact);
    }
  }
  assert.equal(api.opaqueCalls(), before, 'invalid named input never enters business code');
}

async function namedRetention(api) {
  let pending;
  const pendingValues = (() => {
    const first = {namedPending: 'first'};
    const second = {namedPending: 'second'};
    pending = api.waitNamed({first, second});
    assert(pending instanceof Promise);
    return [new WeakRef(first), new WeakRef(second)];
  })();
  await keep(api, () => pendingValues.every(ref => ref.deref()), 'pending named inputs');
  api.completeOpaque(43);
  assert.equal(await pending, 43);
  await collect(api, () => pendingValues.every(ref => !ref.deref()), 'completed named inputs');

  let store;
  const storedValues = (() => {
    const first = {namedStored: 'first'};
    const second = {namedStored: 'second'};
    store = api.NamedStore.withMarker(9, {first, second});
    return [new WeakRef(first), new WeakRef(second)];
  })();
  await keep(api, () => storedValues.every(ref => ref.deref()), 'stored named inputs');
  assert.equal(store.first, storedValues[0].deref());
  assert.equal(store.second, storedValues[1].deref());
  store.clear();
  await collect(api, () => storedValues.every(ref => !ref.deref()), 'cleared named inputs');
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
  let setterCalls = 0;
  const setterValue = resolve => { setterCalls++; resolve(42); };
  const setterOnly = new api.SetterThenBox(setterValue);
  assert.equal(setterOnly.then, undefined);
  assert.equal(setterOnly.value, setterValue);
  assert.equal(await setterOnly.futureSelf(), setterOnly);
  assert.equal(await api.futureIdentity(setterOnly), setterOnly);
  setterOnly.then = resolve => { setterCalls++; resolve(43); };
  assert.equal(setterOnly.then, undefined);
  assert.equal(await setterOnly.futureSelf(), setterOnly);
  assert.equal(setterCalls, 0, 'Promise resolution never invokes a setter-only then');
  let staticSetterCalls = 0;
  api.StaticSetterThenBox.then = () => { staticSetterCalls++; };
  assert.equal(staticSetterCalls, 1);
  assert.equal(api.StaticSetterThenBox.then, undefined);
  assert.equal(await api.futureIdentity(api.StaticSetterThenBox), api.StaticSetterThenBox);
  assert.equal(staticSetterCalls, 1, 'Promise resolution does not invoke a static setter');
  let compositeCalls = 0;
  const compositeValue = resolve => { compositeCalls++; resolve(45); };
  const composite = api.compositeThen(compositeValue);
  assert.equal(composite.then, compositeValue, 'an unselected implementation composes getter and setter views');
  assert.equal(await api.futureIdentity(composite), 45);
  assert.equal(await composite.futureSelf(), 45);
  assert.equal(compositeCalls, 2);
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
    case 'nested':
      await nestedValues(api);
      await nestedValues(await import('@napi/opaque-external'));
      break;
    case 'nested-retention':
      await nestedRetention(api);
      await nestedRetention(await import('@napi/opaque-external'));
      break;
    case 'presence': presence(api); break;
    case 'named':
      await namedPresence(api);
      await namedPresence(await import('@napi/opaque-external'));
      break;
    case 'named-retention':
      await namedRetention(api);
      await namedRetention(await import('@napi/opaque-external'));
      break;
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
      const setter = new external.SetterThenBox(resolve => resolve(46));
      assert.equal(setter.then, undefined);
      assert.equal(await setter.futureSelf(), setter);
      assert.equal(await external.plainFuture(setter), setter);
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
    case 'methods':
      await methods(api);
      break;
    case 'method-retention':
      await methodRetention(api);
      break;
    case 'inherited-methods':
      await inheritedMethods(api);
      break;
    case 'method-resources':
      await methodResources(api);
      break;
    case 'hierarchy':
      await hierarchy(api);
      await hierarchy(await import('@napi/opaque-external'));
      break;
    case 'hierarchy-retention':
      await hierarchyRetention(api, collect, keep);
      break;
    case 'independent': {
      const entry = fileURLToPath(import.meta.resolve(packageName));
      const copied = mkdtempSync(join(process.cwd(), 'independent opaque 雪 '));
      cpSync(dirname(entry), copied, {recursive: true});
      const other = await import(pathToFileURL(join(copied, basename(entry))));
      const foreignChild = new other.OpaqueChild({foreign: true});
      assert.throws(() => api.opaqueAsBase(foreignChild), TypeError);
      assert.throws(() => api.OpaqueBase.prototype.read.call(foreignChild), TypeError);
      const local = new api.OpaqueChild(foreignChild);
      assert.equal(local.read(), foreignChild);
      assert.equal(other.opaqueAsBase(foreignChild), foreignChild);
      const foreign = new other.Router();
      assert.throws(() => new api.NestedStore().references([new other.NamedStore()]), TypeError);
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
  for (const entry of [api, await import('@napi/opaque-external')]) {
    const copied = entry.opaqueValueCallback({value, optional: undefined}, argument => argument);
    assert.equal(copied.value, value);
    assert.equal(copied.optional, undefined);
    assert.deepEqual(copied.items, []);
  }
  router.set('value', value);
  assert.equal(router.get('value'), value);
  assert.equal(await api.futureIdentity(value), value);
  assert.equal(await api.futureIdentity(undefined), undefined);
  assert.equal(await api.futureIdentity({then(resolve) { resolve(17); }}), 17);
  const nested = new api.NestedStore();
  nested.values = [value];
  assert.equal(nested.lists([[undefined]])[0][0], undefined);
  assert.equal((await nested.futureList([value]))[0], value);
  nested.hold([value]);
  const methodBox = new api.MethodBox(value);
  assert.equal(methodBox.echo(undefined), undefined);
  assert.equal(await methodBox.later(value), value);
  methodBox.wait({methodPending: true});
  router.pin();
  const child = new api.OpaqueChild(value);
  assert.equal(api.opaqueAsBase(child), child);
  child.pin();
  child.wait({pending: true});
  api.opaquePressure(1);
  if (workerData.held) {
    setInterval(() => {}, 1000);
    parentPort.postMessage('ready');
  }
} else if (process.argv[2]) {
  await scenario(process.argv[2]);
} else {
  const cases = ['values', 'nested', 'nested-retention', 'presence', 'future-values', 'thenables', 'future-unhandled',
    'external', 'named', 'named-retention', 'retention', 'overwrite-remove',
    'cycles', 'pending', 'methods', 'inherited-methods', 'method-retention', 'method-resources', 'hierarchy', 'hierarchy-retention', 'independent', 'worker-only', 'workers-with-main'];
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
