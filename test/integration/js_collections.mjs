import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {runInNewContext} from 'node:vm';
import {Worker, isMainThread, parentPort, workerData} from 'node:worker_threads';

const tick = () => new Promise(resolve => setImmediate(resolve));
async function collect(api, predicate) {
  for (let i = 0; i < 80; i++) {
    await tick(); api.pressure(i); global.gc(); await tick();
    if (predicate()) return;
  }
  assert(predicate(), 'expected the Dart handle to be released');
}
function exact(action, expected) {
  let caught = false;
  try { action(); } catch (error) {caught = true; assert.equal(error, expected);}
  assert(caught);
}
async function until(predicate, message) {
  for (let i = 0; i < 100; i++) {
    if (predicate()) return;
    await tick();
  }
  assert.fail(message);
}
async function direct(api) {
  const source = [1, 2];
  assert.equal(api.remember(source), source); assert(api.same(source));
  source[0] = 8; assert.equal(api.read(0), 8);
  api.write(1, 9); assert.equal(source[1], 9);
  api.write(3, 10); assert.equal(source.length, 4);
  assert.throws(() => api.read(2), TypeError); assert.equal(api.read(4), null);
  source.length = 1; assert.equal(api.length(), 1);
  for (const index of [-1, 0xffffffff, 2 ** 32]) assert.throws(() => api.read(index), RangeError);
  const huge = []; huge.length = 0xffffffff;
  api.remember(huge); assert.equal(api.length(), 0xffffffff); assert.throws(() => api.read(0), TypeError);
  assert.equal(api.optional(), null); assert.equal(api.optional(undefined), null);
  assert.equal(api.optional(null), null); assert.equal(api.optional(source), source);
  assert.equal(api.named(), null); assert.equal(api.named({value: source}), source);
  const holder = new api.Holder(source); assert.equal(holder.value, source);
  holder.value = [15]; assert.equal(holder.read(0), 15);
  const copied = api.copied([1]); assert.deepEqual(copied, [2]);
  assert.throws(() => api.fake(), TypeError);
  api.remember(source); assert.throws(() => api.wrongPolicy(), TypeError);
}
async function scalars(api) {
  for (const [fn, values] of [[api.booleans, [true, false]], [api.bigBooleans, [true]],
    [api.strings, ['', '\ud800', '\udfff', '雪\0a']], [api.doubles, [NaN, Infinity, -Infinity, -0]],
    [api.int64, [-(1n << 63n), (1n << 63n) - 1n]], [api.bigints, [1n << 200n]]]) {
    for (const value of values) {const source = [value]; assert.equal(fn(source), source); assert(Object.is(source[0], value));}
  }
  const nullable = [null]; assert.equal(api.nullable(nullable), nullable);
  assert.throws(() => api.nullable([undefined]), TypeError);
  for (const bad of [null, undefined, 1.5, NaN, Infinity, 2 ** 53, 1n, '1']) {
    api.remember([bad]); assert.throws(() => api.read(0), typeof bad === 'number' ? RangeError : TypeError);
  }
  for (const bad of [1, 1n << 63n, -(1n << 63n) - 1n]) assert.throws(() => api.int64([bad]), typeof bad === 'bigint' ? RangeError : TypeError);
  assert.throws(() => api.booleans([1]), TypeError); assert.throws(() => api.strings([{}]), TypeError);
  assert.throws(() => api.doubles([1n]), TypeError); assert.throws(() => api.bigints([1]), TypeError);
}
async function maps(api) {
  const source = new Map([['one', 1], ['null', null]]);
  assert.equal(api.rememberMap(source), source); assert(api.sameMap(source));
  assert.equal(api.size(), 2); assert(api.has('null')); assert.equal(api.get('null'), null);
  assert(!api.has('absent')); assert.equal(api.get('absent'), null);
  api.put('one', 2); assert.equal(source.get('one'), 2);
  source.set('bad', undefined); assert(api.has('bad')); assert.throws(() => api.get('bad'), TypeError);
  assert(api.remove('bad')); assert(!api.remove('bad'));
  api.iterate(); assert.equal(api.next(), 'one:2');
  source.set('last', 3); assert.equal(api.next(), 'null:null'); assert.equal(api.next(), 'last:3');
  assert.equal(api.next(), null); source.set('later', 4); assert.equal(api.next(), null);
  api.rememberMap(source); api.clear(); assert.equal(source.size, 0);
  for (const key of [NaN, Infinity, -Infinity, -0]) assert(api.doubleKey(new Map([[key, 'x']]), key));
  assert(api.intKey(new Map([[1n, 'x']]), 1n)); assert(!api.intKey(new Map([[1, 'x']]), 1n));
  assert(api.bigKey(new Map([[1n << 100n, 'x']]), 1n << 100n));
  assert(api.nullKey(new Map([[null, true]])));
  const values = new Map([['a', 1], ['b', 2], ['c', 3]]);
  api.rememberMap(values); api.iterate(); assert.equal(api.next(), 'a:1');
  values.delete('b'); values.set('a', 4); values.set('d', 5);
  assert.equal(api.next(), 'c:3'); values.clear(); values.set('e', 6);
  assert.equal(api.next(), 'e:6'); assert.equal(api.next(), null);
  values.set('f', 7); assert.equal(api.next(), null);
  const iteratorPrototype = Object.getPrototypeOf(new Map().entries());
  const next = iteratorPrototype.next;
  try {
    iteratorPrototype.next = () => {throw 'changed next';};
    api.rememberMap(values); api.iterate();
    assert.equal(api.next(), 'e:6'); assert.equal(api.next(), 'f:7'); assert.equal(api.next(), null);
  } finally {iteratorPrototype.next = next;}
  api.rememberMap(new Map([[42, 1]])); api.iterate(); assert.throws(() => api.next(), TypeError);
}
async function accessors(api) {
  for (const reason of [undefined, null, 17, Symbol('reason'), {reason: 1}]) {
    const source = []; Object.defineProperty(source, '0', {get() {throw reason;}, set() {throw reason;}});
    api.remember(source); exact(() => api.read(0), reason); exact(() => api.write(0, 1), reason);
    assert.equal(api.caught(0), 1);
    try {await api.delayedRead(0); assert.fail('expected rejection');} catch (error) {assert.equal(error, reason);}
  }
  let gets = 0, sets = 0;
  const source = []; Object.defineProperty(source, '0', {get() {gets++; return api.length();}, set(value) {sets = value;}});
  api.remember(source); assert.equal(gets, 0); assert.equal(api.read(0), 1); api.write(0, 12); assert.equal(sets, 12);
  const inherited = Object.create(Array.prototype, {'0': {get() {return 19;}}});
  const sparse = new Array(1); Object.setPrototypeOf(sparse, inherited);
  assert.equal(api.remember(sparse), sparse); assert.equal(api.read(0), 19);
  Object.setPrototypeOf(sparse, Object.create(Array.prototype, {'0': {value: 20}}));
  assert.equal(api.read(0), 20);
  api.remember(Object.freeze([1])); assert.throws(() => api.write(0, 2), TypeError);
  const released = []; Object.defineProperty(released, '0', {get() {api.drop(); global.gc(); return 79;}});
  api.remember(released); assert.equal(api.read(0), 79);
  api.remember([80]); assert.equal(api.read(0), 80);
}
async function admission(api) {
  let traps = 0;
  for (const bad of [null, undefined, {}, new Map(), new Uint8Array(1), new Proxy([], {get() {traps++; throw 1;}})]) {
    assert.throws(() => api.remember(bad), TypeError);
  }
  assert.equal(traps, 0);
  for (const bad of [null, undefined, {}, [], new Proxy(new Map(), {})]) assert.throws(() => api.rememberMap(bad), TypeError);
  const array = runInNewContext('[1, 2]'), map = runInNewContext('new Map([["a", 3]])');
  assert.equal(api.remember(array), array); api.write(0, 4); assert.equal(array[0], 4);
  assert.equal(api.rememberMap(map), map); assert.equal(api.get('a'), 3);
  const count = api.entered(); assert.throws(() => api.partial([], 0), TypeError); assert.equal(api.entered(), count);
  const other = await import('@napi/js-collections-external');
  assert.equal(other.remember(array), array); assert.equal(api.remember(array), array);
  other.write(0, 21); assert.equal(api.read(0), 21);
}
async function captures(api) {
  const source = new Map([['a', 1]]), array = [1]; api.rememberMap(source); api.remember(array);
  const originals = new Map();
  for (const name of ['get', 'set', 'has', 'delete', 'clear', 'entries']) originals.set(name, Map.prototype[name]);
  const weakGet = WeakMap.prototype.get, weakSet = WeakMap.prototype.set, deref = WeakRef.prototype.deref;
  const get = Reflect.get, set = Reflect.set, safe = Number.isSafeInteger;
  try {
    for (const name of originals.keys()) Map.prototype[name] = () => {throw 'polluted';};
    WeakMap.prototype.get = WeakMap.prototype.set = WeakRef.prototype.deref = () => {throw 'polluted';};
    Reflect.get = Reflect.set = () => {throw 'polluted';};
    assert.equal(api.get('a'), 1); api.put('b', 2); assert(api.has('b')); assert(api.remove('a'));
    assert(api.same(array)); api.iterate(); assert.equal(api.next(), 'b:2'); assert.equal(api.next(), null);
    assert.equal(api.read(0), 1); api.write(0, 2); assert.equal(api.read(0), 2);
    Number.isSafeInteger = () => {throw 'polluted';};
    const flags = [true]; assert.equal(api.booleans(flags), flags);
  } finally {
    for (const [name, fn] of originals) Map.prototype[name] = fn;
    WeakMap.prototype.get = weakGet; WeakMap.prototype.set = weakSet; WeakRef.prototype.deref = deref;
    Reflect.get = get; Reflect.set = set; Number.isSafeInteger = safe;
  }
}
async function futures(api) {
  const source = [1]; const pending = api.later(source); source[0] = 3;
  assert.equal(await pending, source);
  const thenable = [1]; thenable.then = resolve => resolve(41);
  assert.equal(api.remember(thenable), thenable); assert.equal(await api.later(thenable), 41);
  for (const reason of [undefined, null, {why: 1}]) {
    const bad = [1]; Object.defineProperty(bad, 'then', {get() {throw reason;}});
    assert.equal(api.remember(bad), bad);
    try {await api.later(bad); assert.fail('expected rejection');} catch (error) {assert.equal(error, reason);}
  }
  const map = new Map([['a', 1]]); assert.equal(await api.laterMap(map), map);
  const owner = new api.Owner(); const work = owner.retain(source), close = owner.close();
  let closed = false; close.then(() => closed = true);
  for (let i = 0; i < 4; i++) {await tick(); api.pressure(i); global.gc(); await tick();}
  assert(!closed); api.complete();
  assert.equal(await work, source); assert.equal(await close, undefined);
}
async function streams(api) {
  const source = [1]; Object.defineProperty(source, 'then', {get() {throw new Error('item then');}});
  const stream = api.events(source), first = stream.next(); source[0] = 8;
  assert.equal((await first).value, source); assert.equal((await stream.next()).value, source);
  assert.equal((await stream.next()).done, true); await stream.return();
  const map = new Map(); map.then = resolve => resolve(42);
  const events = api.mapEvents(map); assert.equal((await events.next()).value, map); await events.return();
}
async function retained(api) {
  const source = [7]; api.remember(source);
  for (let i = 0; i < 4; i++) {await tick(); api.pressure(i); global.gc(); await tick();}
  assert(api.alive()); assert(api.same(source));
  api.drop(); await collect(api, () => !api.alive());
  assert.equal(source[0], 7); // The JS source alone must not pin the Dart handle.
  const map = new Map([['a', 1], ['b', 2]]); api.rememberMap(map); api.iterate();
  for (let i = 0; i < 4; i++) {await tick(); api.pressure(i); global.gc(); await tick();}
  assert(api.mapAlive()); assert.equal(api.next(), 'a:1');
  for (let i = 0; i < 4; i++) {await tick(); api.pressure(i); global.gc(); await tick();}
  assert(api.mapAlive()); assert(api.sameMap(map)); assert.equal(api.next(), 'b:2');
  api.drop(); await collect(api, () => !api.mapAlive());
  let owned = [23]; const ownedWeak = new WeakRef(owned); api.remember(owned); owned = null;
  for (let i = 0; i < 4; i++) {await tick(); api.pressure(i); global.gc(); await tick();}
  assert(ownedWeak.deref()); assert.equal(api.read(0), 23);
  api.drop(); await collect(api, () => ownedWeak.deref() === undefined);
  let input = [31]; const inputWeak = new WeakRef(input); let pending = api.hold(input); input = null;
  for (let i = 0; i < 4; i++) {await tick(); api.pressure(i); global.gc(); await tick();}
  assert(inputWeak.deref()); api.complete(); assert.equal((await pending)[0], 31); pending = null;
  await collect(api, () => inputWeak.deref() === undefined);
  let transient = [5]; const weak = new WeakRef(transient);
  assert.throws(() => api.partial(transient, null), TypeError); transient = null;
  await collect(api, () => weak.deref() === undefined);
}
async function opaque(api) {
  const object = {id: 1}, fn = () => 2, symbol = Symbol('payload');
  let traps = 0;
  const trapped = new Proxy({}, {get() {traps++; throw 'payload inspected';}, getPrototypeOf() {traps++; throw 'payload inspected';}});
  const revoked = Proxy.revocable({}, {}); revoked.revoke();
  for (const payload of [null, undefined, object, fn, symbol, trapped, revoked.proxy, 1n << 200n, NaN, -0, '\ud800']) {
    const source = [payload], box = new api.ArrayPayloads(source);
    assert.equal(box.source(), source); assert(box.same(source));
    assert(box.load(0));
    source.length = 0; box.dropSource();
    assert(Object.is(box.saved(), payload));
    box.clearSaved(); assert.equal(box.saved(), null);
  }
  assert.equal(traps, 0);
  const hole = new Array(1), holes = new api.ArrayPayloads(hole);
  assert(holes.load(0)); assert.equal(holes.saved(), undefined);
  assert(!holes.load(1)); assert.equal(holes.saved(), null);
  for (const payload of [null, undefined, object]) {
    const source = [payload]; assert(api.nullablePayload(source));
    assert.equal(source[1], null);
  }
  const nullMap = new Map(); assert(api.nullableMapPayload(nullMap));
  assert(nullMap.has(null)); assert.equal(nullMap.get(null), null);
  const source = new Map([[undefined, undefined], [null, null], [object, symbol]]);
  const map = new api.MapPayloads(source);
  assert.equal(map.source(), source);
  assert(map.has(undefined)); assert(map.load(undefined)); assert.equal(map.saved(), undefined);
  assert(map.load(null)); assert.equal(map.saved(), null);
  assert(!map.load({id: 1})); assert.equal(map.saved(), null);
  assert.equal(map.get(object), symbol);
  map.put(object, fn); assert.equal(source.get(object), fn);
  map.put(NaN, object); assert.equal(map.get(NaN), object);
  map.put(-0, symbol); assert.equal(map.get(+0), symbol);
  map.put(revoked.proxy, trapped); assert.equal(map.get(revoked.proxy), trapped);
  map.start(); assert(map.next()); assert.equal(map.key(), undefined); assert.equal(map.value(), undefined);
  assert(map.next()); assert.equal(map.key(), null); assert.equal(map.value(), null);
  while (map.next()) {}
  source.set('later', 2); assert(!map.next()); map.dropIterator();
  assert(map.remove(revoked.proxy)); assert(!map.has(revoked.proxy));
  const mixed = new Map([['key', undefined]]);
  assert.equal(api.stringPayload(mixed, 'key'), undefined);
  assert.equal(api.firstPayload(mixed), undefined);
  assert.equal(api.keyedScalar(new Map([[object, 3]]), object), 3);
  assert.equal(api.firstScalar(new Map([[object, 4]])), 4);
  assert.throws(() => api.keyedScalar(new Map([[object, undefined]]), object), TypeError);
  assert.throws(() => api.firstPayload(new Map([[5, object]])), TypeError);
  assert.throws(() => api.firstScalar(new Map([[object, 'bad']])), TypeError);
  const a = [1]; assert(api.renamedPolicy(a, a)); assert(!api.numberPolicy(a, a));
  const foreign = runInNewContext('({array: [undefined], map: new Map([[null, undefined]])})');
  const foreignArray = new api.ArrayPayloads(foreign.array);
  assert(foreignArray.load(0)); assert.equal(foreignArray.saved(), undefined);
  assert.equal(new api.MapPayloads(foreign.map).get(null), undefined);
  assert.throws(() => new api.ArrayPayloads(new Proxy([], {})), TypeError);
  assert.throws(() => new api.MapPayloads(new Proxy(new Map(), {})), TypeError);
  for (const reason of [undefined, null, symbol, object]) {
    const source = []; Object.defineProperty(source, '0', {get() {throw reason;}, set() {throw reason;}});
    const box = new api.ArrayPayloads(source);
    exact(() => box.load(0), reason); exact(() => box.put(0, undefined), reason);
    try {await box.captured(0); assert.fail('expected rejection');} catch (error) {assert.equal(error, reason);}
  }
  const reentrant = [], box = new api.ArrayPayloads(reentrant);
  Object.defineProperty(reentrant, '0', {get() {box.dropSource(); global.gc(); return object;}});
  assert(box.load(0)); assert.equal(box.saved(), object);
  const flags = [true], descriptor = Object.getOwnPropertyDescriptor(Object.prototype, 'opaque');
  try {
    Object.defineProperty(Object.prototype, 'opaque', {configurable: true, value: true});
    assert.equal(api.booleans(flags), flags); assert.throws(() => api.booleans([1]), TypeError);
  } finally {
    if (descriptor) Object.defineProperty(Object.prototype, 'opaque', descriptor);
    else delete Object.prototype.opaque;
  }
  assert.equal(traps, 0);
}
async function opaqueAsync(api) {
  const object = {id: 1}, source = [object], box = new api.ArrayPayloads(source);
  const pending = box.captured(10); source.length = 0; box.dropSource();
  assert.equal(await pending, object);
  const thenable = {then(resolve) {resolve(97);}}, value = new api.ArrayPayloads([thenable]);
  assert.equal(await value.captured(0), 97);
  assert(value.load(0));
  const iterator = value.events(); assert.equal((await iterator.next()).value, thenable); await iterator.return();
  const throwing = {get then() {throw object;}};
  value.put(0, throwing); assert(value.load(0));
  const throwingEvents = value.events(); assert.equal((await throwingEvents.next()).value, throwing); await throwingEvents.return();
  const container = [undefined], handles = new api.ArrayPayloads(container);
  assert.equal(await handles.later(), container);
  const handleEvents = handles.sources(); container[0] = object;
  assert.equal((await handleEvents.next()).value, container); await handleEvents.return();
  container.then = resolve => resolve(8); assert.equal(await handles.later(), 8);
  // An opaque wrapper is retained as a value, not a permanent resource lease.
  const owner = new api.Owner(), resource = new api.ArrayPayloads([owner]);
  assert(resource.load(0)); await owner.close(); assert.equal(resource.saved(), owner);
}
async function opaqueRetained(api) {
  const source = [];
  const box = new api.ArrayPayloads(source);
  let payload = {kept: true}; const weak = new WeakRef(payload);
  source.push(payload); assert(box.load(0)); payload = null; source.length = 0; box.dropSource();
  await collect(api, () => !box.alive());
  assert(weak.deref()); assert.equal(box.saved(), weak.deref());
  box.clearSaved(); await collect(api, () => weak.deref() === undefined);
  // Replacement can precede the old adapter finalizer; it must stay cached.
  for (let i = 0; i < 12; i++) {
    box.remember(source); assert(box.same(source)); box.dropSource();
    await collect(api, () => !box.alive());
    box.remember(source); await tick(); global.gc(); await tick(); assert(box.same(source));
  }
  box.dropSource();
  let key = {}, value = {}; const keyWeak = new WeakRef(key), valueWeak = new WeakRef(value);
  const raw = new Map([[key, value]]), map = new api.MapPayloads(raw);
  map.start(); assert(map.next()); raw.clear(); key = null; value = null;
  for (let i = 0; i < 4; i++) {await tick(); api.pressure(i); global.gc(); await tick();}
  assert.equal(map.key(), keyWeak.deref()); assert(keyWeak.deref());
  assert.equal(map.value(), valueWeak.deref()); assert(valueWeak.deref());
  map.dropIterator(); await collect(api, () => keyWeak.deref() === undefined && valueWeak.deref() === undefined);
  let failedKey = {}; const failedWeak = new WeakRef(failedKey);
  const invalid = new Map([[failedKey, 'invalid scalar']]);
  assert.throws(() => api.firstScalar(invalid), TypeError);
  invalid.clear(); failedKey = null;
  await collect(api, () => failedWeak.deref() === undefined);
}
async function nested(api) {
  const array = [7], map = new Map([['key', 8]]);
  const input = {arrays: [array, null], maps: new Map([['first', map], ['null', null]]), dictionaries: {leaf: array}};
  const check = output => {
    assert.notEqual(output, input); assert.notEqual(output.arrays, input.arrays);
    assert.notEqual(output.maps, input.maps); assert.notEqual(output.dictionaries, input.dictionaries);
    assert.equal(output.arrays[0], array); assert.equal(output.arrays[1], null);
    assert.equal(output.maps.get('first'), map); assert.equal(output.maps.get('null'), null);
    assert.equal(output.dictionaries.leaf, array);
  };
  check(api.nested(input));
  array[0] = 11; assert.equal(api.nestedAccess(input, false), 11);
  assert.equal(api.nestedAccess(input, true), 42); assert.equal(array[0], 42); assert.equal(map.get('key'), 43);
  const copies = api.nested(input); copies.arrays.length = 0; copies.maps.clear(); delete copies.dictionaries.leaf;
  assert.equal(input.arrays.length, 2); assert.equal(input.maps.size, 2); assert.equal(input.dictionaries.leaf, array);
  let gets = 0;
  const lazy = []; Object.defineProperty(lazy, '0', {get() {gets++; throw 'lazy nested access';}});
  const lazyInput = {...input, arrays: [lazy]};
  assert.equal(api.nested(lazyInput).arrays[0], lazy); assert.equal(gets, 0);
  exact(() => api.nestedAccess(lazyInput, false), 'lazy nested access'); assert.equal(gets, 1);
  api.nested(input);
  const entered = api.entered();
  for (const bad of [
    {...input, arrays: [undefined]}, {...input, arrays: new Array(1)},
    {...input, maps: new Map([['first', undefined]])},
    {...input, dictionaries: {leaf: undefined}}, {...input, dictionaries: {leaf: null}},
  ]) assert.throws(() => api.nested(bad), TypeError);
  assert.equal(api.entered(), entered); assert.equal(api.read(0), 42);
  // A later sibling failure must not invalidate an already cached adapter.
  assert.throws(() => api.nested({...input, maps: new Map([['first', {}]])}), TypeError);
  assert.equal(api.read(0), 42); api.write(0, 44); assert.equal(array[0], 44);
  const fresh = [53], value = {array: fresh, map};
  // The first parameter's constructor saves its adapter before the next parameter fails.
  assert.throws(() => api.nestedValue(value, ['bad']), TypeError);
  assert.equal(api.read(0), 53); api.write(0, 54); assert.equal(fresh[0], 54);
  const projected = api.nestedValue(value, []);
  assert.notEqual(projected, value); assert.equal(projected.array, fresh); assert.equal(projected.map, map);
  const original = [61], replacement = [62], trigger = [];
  const captured = {first: {trigger}, last: original};
  let reentered = 0;
  Object.defineProperty(trigger, '0', {get() {reentered++; captured.last = replacement; return 1;}});
  // The constructor reenters JS after normalization has captured every source.
  assert.equal(api.nestedCaptured(captured)[0], original);
  assert.equal(captured.last, replacement); assert.equal(reentered, 1);
  for (const fn of [api.nestedFake, api.nestedWrongPolicy]) {
    assert.throws(() => fn(false), error => error instanceof TypeError && /first/.test(error.message));
    assert.equal(api.nestedOrder(), 'first;last;');
    assert.throws(() => fn(true), error => !(error instanceof TypeError) && /later nested getter/.test(error.message));
    assert.equal(api.nestedOrder(), 'first;last;');
    assert.equal(api.read(0), 54);
  }
  const payload = {then() {throw 'nested then must not run';}}, raw = [undefined, payload];
  const nestedPayload = [raw], payloadOutput = api.nestedPayloads(nestedPayload);
  assert.notEqual(payloadOutput, nestedPayload); assert.equal(payloadOutput[0], raw);
  Object.defineProperty(array, 'then', {get() {throw 'array then must not run';}, configurable: true});
  check(await api.nestedLater(input));
  const events = api.nestedEvents(input); check((await events.next()).value); await events.return();
  delete array.then;
  const other = await import('@napi/js-collections-external');
  assert.equal(other.nested(input).arrays[0], array);
  assert.equal(api.nested(input).arrays[0], array);
  // Raw containers may be admitted by a different policy and module.
  assert.equal(other.nestedPayloads([array])[0], array);
  assert.equal(api.nestedPayloads([array])[0], array);
}
async function nestedHandles(api) {
  const payload = {id: 1}, inner = [undefined, null, payload], outer = [];
  let gets = 0;
  Object.defineProperty(outer, '0', {configurable: true, get() {gets++; return inner;}});
  const arrays = new api.NestedArrays(outer);
  assert.equal(arrays.source(), outer); assert.equal(gets, 0);
  assert(arrays.load(0)); assert.equal(gets, 1);
  assert.equal(arrays.saved(), inner); assert(arrays.same(inner));
  assert.equal(arrays.read(0), undefined); assert.equal(arrays.read(1), null);
  arrays.replace(1); assert.equal(outer[1], inner);
  const pending = arrays.delayedRead(2);
  outer.length = 0; inner[2] = undefined;
  assert.equal(await pending, undefined);
  arrays.put(2, payload); assert.equal(inner[2], payload);
  const reason = Symbol('nested getter');
  Object.defineProperty(outer, '0', {configurable: true, get() {throw reason;}});
  exact(() => arrays.load(0), reason);
  Object.defineProperty(outer, '0', {configurable: true, writable: true, value: null});
  assert(!arrays.load(0)); assert.equal(arrays.saved(), null);
  outer[0] = undefined; assert.throws(() => arrays.load(0), TypeError);

  // Entry handles keep the live child containers after the outer Map is cleared.
  const key = [11], values = new Map([['undefined', undefined], ['null', null], ['object', payload]]);
  const graph = new Map([[key, values]]), maps = new api.NestedMaps(graph);
  assert.equal(maps.source(), graph);
  maps.start(); assert(maps.next()); graph.clear();
  assert.equal(maps.key(), key); assert(maps.sameKey(key));
  assert.equal(maps.value(), values); assert(maps.sameValue(values));
  assert.equal(maps.read('undefined'), undefined); assert.equal(maps.read('null'), null);
  assert.equal(maps.read('object'), payload);
  key[0] = 12; assert.equal(maps.readKey(0), 12);
  maps.writeKey(0, 13); assert.equal(key[0], 13);
  maps.put('new', undefined); assert(values.has('new')); assert.equal(values.get('new'), undefined);
  maps.putEntry(key, values); assert.equal(graph.get(key), values);
  for (const graph of [new Map([[{}, values]]), new Map([[key, []]])]) {
    const invalid = new api.NestedMaps(graph); invalid.start();
    assert.throws(() => invalid.next(), TypeError);
  }

  const numbers = [[21]], bigints = [[1n << 62n]];
  assert.equal(api.nestedNumbers(numbers), numbers);
  assert.equal(api.nestedInt64(bigints), bigints);
  assert.throws(() => api.nestedNumbers([[1n]]), TypeError);
  assert.throws(() => api.nestedInt64([[1]]), TypeError);
  assert.throws(() => api.nestedInt64([[1n << 63n]]), RangeError);
  assert.throws(() => api.nestedNumbers([[2 ** 53]]), RangeError);
  assert.throws(() => api.nestedWriteWrongPolicy(bigints), TypeError);
  assert.equal(bigints[0][0], 1n << 62n);
  assert.throws(() => api.nestedFakeWrite(numbers), TypeError);
  assert.equal(numbers[0][0], 21);
  const callbackSource = [inner, null];
  assert.equal(api.nestedCallback(value => {
    assert.equal(value, callbackSource); return value;
  }, callbackSource), inner);
  assert.equal(await api.nestedAsyncCallback(async value => {
    assert.equal(value, callbackSource); await tick(); return value;
  }, callbackSource), inner);
}
async function references(api) {
  const first = new api.RefItem(1), child = new api.RefChild(2);
  const array = [first, null], map = new Map([[first, child]]);
  const refs = new api.ReferenceCollections(array, map);
  assert.equal(refs.array(), array); assert.equal(refs.map(), map);
  assert.equal(refs.read(0), first); assert.equal(refs.read(1), null);
  assert.equal(refs.read(2), null); assert(refs.has(first));
  assert(!refs.has(new api.RefItem(1))); assert.equal(refs.get(first), child);
  assert.equal(refs.get(child), null);
  refs.write(0, child); assert.equal(array[0], child);
  child.value = 3; assert.equal(refs.read(0).value, 3);
  refs.write(1, first); assert.equal(array[1], first);
  refs.write(1, null); assert.equal(array[1], null);
  refs.put(child, first); assert.equal(map.get(child), first);
  refs.put(first, null); assert(map.has(first)); assert.equal(map.get(first), null);
  refs.start(); assert(refs.next()); assert.equal(refs.key(), first); assert.equal(refs.value(), null);
  assert(refs.next()); map.clear();
  assert.equal(refs.key(), child); assert.equal(refs.value(), first);
  refs.put(child, first); assert(refs.remove(child)); assert(!refs.remove(child));

  let gets = 0;
  const lazy = []; Object.defineProperty(lazy, '0', {get() {gets++; return first;}});
  const lazyRefs = new api.ReferenceCollections(lazy, new Map());
  assert.equal(gets, 0); assert.equal(lazyRefs.read(0), first); assert.equal(gets, 1);
  const reason = Symbol('reference getter');
  const throwing = []; Object.defineProperty(throwing, '0', {get() {throw reason;}});
  exact(() => new api.ReferenceCollections(throwing, new Map()).read(0), reason);
  const reentrant = [], nested = new api.ReferenceCollections(reentrant, new Map());
  Object.defineProperty(reentrant, '0', {get() {assert.equal(nested.array(), reentrant); global.gc(); return child;}});
  assert.equal(nested.read(0), child);
  assert.equal(api.nestedReference([[first]]), first);
  assert.equal(api.referenceCallback(value => {assert.equal(value, array); return value;}, array), child);
  const payload = {id: 1}, box = new api.RefBox(payload);
  assert.equal(api.referenceBox([box]), box); assert.equal(box.value, payload);
  const intItem = new api.IntItem(7), textItem = new api.TextItem('seven');
  assert.equal(api.concreteReference(new Map([[intItem, textItem]]), intItem), textItem);
  assert.throws(() => api.concreteReference(new Map([[intItem, intItem]]), intItem), TypeError);
  for (const [name, value] of [['opaque', true], ['reference', 0]]) {
    const original = Object.getOwnPropertyDescriptor(Object.prototype, name);
    try {
      Object.defineProperty(Object.prototype, name, {configurable: true, value});
      assert.equal(refs.read(0), child);
      refs.write(0, child); assert.equal(array[0], child);
      assert.equal(api.booleans([true])[0], true);
      assert.equal(api.nestedNumbers([[1]])[0][0], 1);
    } finally {
      if (original) Object.defineProperty(Object.prototype, name, original);
      else delete Object.prototype[name];
    }
  }

  const delayed = refs.delayedRead(0); array[0] = first;
  assert.equal(await delayed, first);
  const captured = refs.captured(0); array.length = 0;
  await tick(); api.pressure(1); global.gc();
  assert.equal(await captured, first);
  let retained = new api.RefItem(31); const weak = new WeakRef(retained);
  array[0] = retained; refs.save(0); array.length = 0; retained = null;
  await collect(api, () => weak.deref() === undefined);
  const restored = refs.saved(); assert.equal(restored.value, 31);
  refs.write(0, restored); assert.equal(array[0], restored);
  map.set(restored, restored); assert(refs.has(restored)); assert.equal(refs.get(restored), restored);

  let traps = 0;
  const proxy = new Proxy(first, {get() {traps++; throw 'inspected reference';}, getPrototypeOf() {traps++; throw 'inspected reference';}});
  const foreign = await import(api === await import('@napi/js-collections-fixture')
    ? '@napi/js-collections-external' : '@napi/js-collections-fixture');
  const badValues = [undefined, {}, new api.OtherItem(1), Object.create(api.RefItem.prototype), proxy, new foreign.RefItem(1)];
  for (const bad of badValues) {
    const invalid = new api.ReferenceCollections([bad], new Map());
    assert.throws(() => invalid.read(0), TypeError);
    const badKey = new api.ReferenceCollections([], new Map([[bad, first]]));
    badKey.start(); assert.throws(() => badKey.next(), TypeError);
    assert.throws(() => new api.ReferenceCollections([], new Map([[first, bad]])).get(first), TypeError);
  }
  assert.equal(traps, 0);
  const nullKey = new api.ReferenceCollections([], new Map([[null, first]]));
  nullKey.start(); assert.throws(() => nullKey.next(), TypeError);
  assert.throws(() => api.referenceBox([first]), TypeError);
  assert.throws(() => api.referenceBox([null]), TypeError);

  // Ordinary base views still use the actual resource's lifecycle.
  const resource = new api.ResourceItem(41);
  const resourceRefs = new api.ReferenceCollections([resource], new Map([[resource, first], [first, resource]]));
  assert.equal(resourceRefs.read(0), resource);
  assert.equal(await resourceRefs.delayedRead(0), resource);
  assert.equal(await resourceRefs.captured(0), resource);
  assert(resourceRefs.has(resource)); assert.equal(resourceRefs.get(first), resource);
  resourceRefs.start(); assert(resourceRefs.next()); assert.equal(resourceRefs.key(), resource);
  refs.write(0, resource); assert.equal(array[0], resource);
  refs.writeResource(0); assert(array[0] instanceof api.ResourceItem); await array[0].close();
  refs.putResourceKey();
  const createdKey = [...map.keys()].find(key => key instanceof api.ResourceItem);
  assert(createdKey); await createdKey.close(); map.delete(createdKey);
  refs.putResourceValue(restored); assert(map.get(restored) instanceof api.ResourceItem); await map.get(restored).close();
  map.set(restored, restored);
  api.writeReferenceResource(array); assert(array[0] instanceof api.ResourceItem); await array[0].close();
  array[0] = restored;
  assert.throws(() => api.writeConflictingResource(array), TypeError); assert.equal(array[0], restored);
  await resource.close();
  assert.throws(() => resourceRefs.read(0), /clos/i);
}

async function resourceCollections(api) {
  const first = new api.ResourceItem(201), second = new api.ResourceItem(202);
  const array = [first, null], map = new Map([[first, second]]);
  const resources = new api.ResourceCollections(array, map);
  assert.equal(resources.array(), array); assert.equal(resources.map(), map);
  assert.equal(resources.read(0), first); assert.equal(resources.read(1), null);
  resources.write(1, second); assert.equal(array[1], second);
  assert(resources.has(first)); assert.equal(resources.get(first), second);
  resources.put(second, first); assert.equal(map.get(second), first);
  resources.start(); assert(resources.next());
  assert.equal(resources.key(), first); assert.equal(resources.value(), second);
  await first.close(); await second.close();
  assert.throws(() => resources.read(0), /clos/i);

  // Neither storing a handle nor starting a Future eagerly reads its elements.
  const untouched = new api.ResourceItem(203);
  const idle = new api.ResourceCollections([untouched], new Map());
  await untouched.close(); assert.equal(api.collectionCleanups(203), 1);
  assert.throws(() => idle.read(0), /clos/i);
  const beforeRead = new api.ResourceItem(204);
  const late = new api.ResourceCollections([beforeRead], new Map());
  const rejected = assert.rejects(late.hold(4, true), /clos/i);
  await until(() => api.collectionWaiting(1004), 'expected pre-read gate');
  await beforeRead.close(); assert.equal(api.collectionCleanups(204), 1);
  api.collectionComplete(1004); await rejected;

  const afterAwait = new api.ResourceItem(205);
  const delayed = new api.ResourceCollections([afterAwait], new Map());
  const pending = delayed.hold(5, true);
  await until(() => api.collectionWaiting(1005), 'expected delayed first access');
  api.collectionComplete(1005);
  await until(() => api.collectionWaiting(5), 'expected resource accepted after await');
  const closing = afterAwait.close(); assert.equal(api.collectionCleanups(205), 0);
  assert.throws(() => delayed.read(0), /clos/i);
  api.collectionComplete(5); assert.equal(await pending, 205);
  await closing; assert.equal(api.collectionCleanups(205), 1);

  // A cached handle must use the operation of each concurrent and reentrant call.
  const shared = new api.ResourceItem(206), source = [];
  const concurrent = new api.ResourceCollections(source, new Map());
  let reentered = false, inner;
  Object.defineProperty(source, '0', {get() {
    if (!reentered) {reentered = true; inner = concurrent.hold(7, false);}
    return shared;
  }});
  const outer = concurrent.hold(6, false), third = concurrent.hold(8, false);
  await until(() => [6, 7, 8].every(token => api.collectionWaiting(token)), 'expected independent resource operations');
  const sharedClose = shared.close();
  for (const [token, work] of [[6, outer], [7, inner], [8, third]]) {
    assert.equal(api.collectionCleanups(206), 0);
    api.collectionComplete(token); assert.equal(await work, 206);
    await tick();
  }
  await sharedClose; assert.equal(api.collectionCleanups(206), 1);

  const adopted = new api.ResourceItem(207);
  const adoption = new api.ResourceCollections([adopted], new Map());
  let finish, adoptedClose;
  const thenable = {get then() {
    adoptedClose = adopted.close(); assert.equal(api.collectionCleanups(207), 0);
    return resolve => {finish = resolve;};
  }};
  const result = adoption.result(9, thenable);
  await until(() => api.collectionWaiting(9), 'expected result gate');
  api.collectionComplete(9);
  await until(() => finish !== undefined, 'expected result thenable adoption');
  for (let i = 0; i < 3; i++) {await tick(); global.gc(); assert.equal(api.collectionCleanups(207), 0);}
  finish(37); assert.equal(await result, 37); await adoptedClose;
  assert.equal(api.collectionCleanups(207), 1);

  const expired = new api.ResourceItem(208);
  api.collectionTimers([expired], [23]);
  await new Promise(resolve => setTimeout(resolve, 5));
  await until(() => api.collectionTimerResult().length === 2, 'expected detached timer access');
  assert.deepEqual(api.collectionTimerResult(), [1, 23]);
  assert.equal(api.collectionCleanups(208), 0); await expired.close();
}

async function resourceCollectionStreams(api) {
  const resource = new api.ResourceItem(211);
  const holder = new api.ResourceCollections([resource], new Map());
  const stream = holder.watch(11), first = stream.next();
  await until(() => api.collectionWaiting(11), 'expected lazy stream first access');
  api.collectionComplete(11);
  assert.equal((await first).value, 211);
  const pending = stream.next(), closing = resource.close();
  await until(() => api.collectionWaiting(-11), 'expected late resource to cancel stream');
  assert.equal(api.collectionCleanups(211), 0);
  api.collectionComplete(-11); await closing;
  assert.equal((await pending).done, true); await stream.return();
  const events = api.collectionEvents();
  assert(events.indexOf('read:11') < events.indexOf('cancel:11'));
  assert(events.indexOf('cancelled:11') < events.indexOf('close:211'));
}
async function binaryCollections(api) {
  function snapshot(value, expected) {
    assert.deepEqual([...(value instanceof ArrayBuffer ? new Uint8Array(value) : value)], expected);
    assert.equal(Object.getPrototypeOf(value), value instanceof ArrayBuffer ? ArrayBuffer.prototype : Uint8Array.prototype);
    if (value instanceof Uint8Array) {assert.equal(value.byteOffset, 0); assert.equal(value.buffer.byteLength, value.byteLength);}
    assert.equal((value.buffer ?? value).resizable, false);
  }
  const storage = new Uint8Array([90, 1, 2, 91]), view = storage.subarray(1, 3);
  const raw = new Uint8Array([3, 4]).buffer;
  const array = [view, null], map = new Map([['key', raw], ['null', null]]);
  const box = new api.BinaryCollections(array, map);
  assert.equal(box.array(), array); assert.equal(box.map(), map);
  const first = box.read(0), second = box.read(0);
  snapshot(first, [1, 2]); snapshot(second, [1, 2]);
  assert.notEqual(first, view); assert.notEqual(first.buffer, second.buffer);
  first.fill(8); assert.deepEqual([...view], [1, 2]);
  box.save(0); view[0] = 7; snapshot(box.saved(), [1, 2]); snapshot(box.read(0), [7, 2]);
  box.change(5); assert.equal(view[0], 7);
  box.writeSaved(1); snapshot(array[1], [5, 2]);
  box.change(6); snapshot(array[1], [5, 2]);
  box.writeSaved(2); snapshot(array[2], [6, 2]); assert.notEqual(array[1].buffer, array[2].buffer);
  structuredClone(storage.buffer, {transfer: [storage.buffer]}); snapshot(box.saved(), [6, 2]);
  const replacement = new Uint8Array([9, 10]); box.write(0, replacement);
  replacement.fill(0); snapshot(array[0], [9, 10]); assert.notEqual(array[0], replacement);
  box.writeWindow(0); snapshot(array[0], [1, 2]); snapshot(box.saved(), [99, 2]);
  const pending = box.captured(0); array[0][0] = 77;
  structuredClone(array[0].buffer, {transfer: [array[0].buffer]}); snapshot(await pending, [1, 2]);
  box.write(0, null); assert.equal(array[0], null); assert.equal(box.read(0), null);

  box.saveBuffer('key'); new Uint8Array(raw).fill(8); snapshot(box.savedBuffer(), [3, 4]); snapshot(box.get('key'), [8, 8]);
  box.changeBuffer(6); box.putSaved('copy'); snapshot(map.get('copy'), [6, 4]);
  box.changeBuffer(7); snapshot(map.get('copy'), [6, 4]);
  box.putSaved('other'); assert.notEqual(map.get('copy'), map.get('other'));
  structuredClone(raw, {transfer: [raw]}); snapshot(box.savedBuffer(), [7, 4]);
  const inputBuffer = new Uint8Array([8, 9]).buffer;
  box.put('key', inputBuffer); new Uint8Array(inputBuffer).fill(0); snapshot(map.get('key'), [8, 9]);
  box.putWindow('window'); snapshot(map.get('window'), [90, 1, 2, 91]); snapshot(box.savedBuffer(), [99, 1, 2, 91]);
  assert.equal(box.get('null'), null); assert.equal(box.get('absent'), null);
  box.put('nil', null); assert.equal(map.get('nil'), null);

  const foreign = runInNewContext('({bytes: new Uint8Array([11, 12]), buffer: new Uint8Array([13, 14]).buffer})');
  snapshot(new api.BinaryCollections([foreign.bytes], new Map()).read(0), [11, 12]);
  snapshot(new api.BinaryCollections([], new Map([['key', foreign.buffer]])).get('key'), [13, 14]);
  snapshot(new api.BinaryCollections([Buffer.from([15, 16])], new Map()).read(0), [15, 16]);
  let reads = 0;
  const spoofed = new Uint8Array([17]);
  for (const name of ['buffer', 'byteLength', 'byteOffset', 'length', 'constructor']) {
    Object.defineProperty(spoofed, name, {get() {reads++; throw 'binary metadata';}});
  }
  snapshot(new api.BinaryCollections([spoofed], new Map()).read(0), [17]); assert.equal(reads, 0);

  const rab = new ArrayBuffer(8, {maxByteLength: 16}); new Uint8Array(rab).set([90, 1, 2, 3, 4, 5, 6, 91]);
  const fixed = new Uint8Array(rab, 1, 3), tracking = new Uint8Array(rab, 2);
  const resizing = new api.BinaryCollections([fixed, tracking], new Map([['key', rab]]));
  snapshot(resizing.read(0), [1, 2, 3]); rab.resize(5); snapshot(resizing.read(1), [2, 3, 4]);
  rab.resize(3); assert.throws(() => resizing.read(0), TypeError);
  snapshot(resizing.read(1), [2]); snapshot(resizing.get('key'), [90, 1, 2]);
  let traps = 0;
  const proxy = new Proxy(new Uint8Array([1]), {get() {traps++; throw 'binary proxy';}});
  for (const bad of [undefined, {}, new Uint16Array(1), new ArrayBuffer(1), proxy,
    new Uint8Array(new SharedArrayBuffer(1)), view, fixed]) {
    const values = [bad], invalid = new api.BinaryCollections(values, new Map());
    assert.equal(invalid.array(), values); assert.throws(() => invalid.read(0), TypeError);
  }
  for (const bad of [undefined, new Uint8Array(1), new SharedArrayBuffer(1), raw, new Proxy(new ArrayBuffer(1), {})]) {
    const values = new Map([['key', bad]]), invalid = new api.BinaryCollections([], values);
    assert.equal(invalid.map(), values); assert.throws(() => invalid.get('key'), TypeError);
  }
  assert.equal(traps, 0);
  const reason = Symbol('binary setter'), lazy = [];
  let received, gets = 0;
  Object.defineProperty(lazy, '0', {get() {gets++; return new Uint8Array([21]);}, set(value) {received = value; throw reason;}});
  const lazyBox = new api.BinaryCollections(lazy, new Map());
  assert.equal(gets, 0); snapshot(lazyBox.read(0), [21]); assert.equal(gets, 1);
  exact(() => lazyBox.write(0, new Uint8Array([22])), reason); snapshot(received, [22]);
  snapshot(api.nestedBinary([[new Uint8Array([23])]]), [23]);
  snapshot(api.nestedBinary([[new Uint8Array(0)]]), []);
  snapshot(api.nestedBuffer([new Map([['key', new Uint8Array([24]).buffer]])]), [24]);
  assert.throws(() => api.nestedBinary([[null]]), TypeError);
  const callbackSource = [new Uint8Array([25])];
  const output = await api.binaryCallback(async value => {
    assert.equal(value, callbackSource); await tick(); value[0][0] = 26; return value;
  }, callbackSource);
  callbackSource[0][0] = 27; snapshot(output, [26]);
  await assert.rejects(api.binaryCallback(async () => [new Uint16Array(1)], callbackSource), TypeError);

  const originalKey = new Uint8Array([1, 2]), originalValue = new Uint8Array([3, 4]).buffer;
  const keys = new Map([[originalKey, originalValue]]);
  assert(api.copiedBinaryKey(keys)); assert.equal(keys.size, 2);
  assert.equal(keys.get(originalKey), originalValue);
  snapshot(originalKey, [1, 2]); snapshot(originalValue, [3, 4]);
  const [copiedKey, copiedValue] = [...keys][1];
  assert.notEqual(copiedKey, originalKey); assert.notEqual(copiedValue, originalValue);
  snapshot(copiedKey, [7, 2]); snapshot(copiedValue, [8, 4]);
  const nullKeys = new Map([[null, false]]);
  assert(api.nullableBinaryKey(nullKeys)); assert.equal(nullKeys.get(null), true); assert.equal(nullKeys.size, 1);
}
async function sharedByteCollections(api) {
  let source = new Uint8Array([90, 1, 2, 91]).subarray(1, 3);
  const original = new WeakRef(source), peer = new Uint8Array([3, 4]);
  const array = [source, null], map = new Map([[source, peer]]);
  const box = new api.SharedByteCollections(array, map);
  assert.equal(box.array(), array); assert.equal(box.map(), map);
  assert.equal(box.read(0), source); box.save(0); assert.equal(box.saved(), source);
  source[0] = 5; assert.equal(box.readSaved(0), 5);
  box.changeSaved(1, 6); assert.equal(source[1], 6);
  box.writeSaved(1); assert.equal(array[1], source);
  box.captureEntry(); assert.equal(box.key(), source); assert.equal(box.value(), peer);
  assert(box.hasEntry()); assert(box.sameEntryValue()); box.writeEntry(); assert.equal(map.size, 1);
  assert(!api.binarySharedPolicy(array, array));
  array.length = 0; map.clear(); source = null;
  for (let i = 0; i < 4; i++) {await tick(); api.pressure(i); global.gc();}
  assert(original.deref()); assert.equal(box.saved(), original.deref());
  assert.equal(box.readSaved(0), 5); box.changeSaved(0, 7); assert.equal(original.deref()[0], 7);
  box.writeSaved(0); assert.equal(array[0], original.deref());
  box.writeEntry(); assert.equal(map.get(original.deref()), peer);
  box.clear(0); assert.equal(array[0], null); assert.equal(box.read(0), null);
  box.allocate(0); assert.deepEqual([...array[0]], [0, 0]);
  box.changeSaved(0, 8); assert.equal(array[0][0], 8); assert.equal(box.saved(), array[0]);

  const sab = new Uint8Array(new SharedArrayBuffer(2));
  const invalid = new api.SharedByteCollections([sab], new Map());
  assert.throws(() => invalid.read(0), TypeError);
  const detached = new Uint8Array([9]), held = new api.SharedByteCollections([detached], new Map());
  held.save(0); structuredClone(detached.buffer, {transfer: [detached.buffer]});
  assert.throws(() => held.readSaved(0), TypeError); assert.throws(() => held.saved(), TypeError);
  const rab = new ArrayBuffer(4, {maxByteLength: 8}), fixed = new Uint8Array(rab, 1, 2);
  const resizing = new api.SharedByteCollections([fixed], new Map([[fixed, fixed]]));
  resizing.save(0); rab.resize(1);
  assert.throws(() => resizing.readSaved(0), TypeError);
  assert.throws(() => resizing.captureEntry(), TypeError);
}
async function structuralCollections(api) {
  const resourceKey = new api.ResourceItem(221);
  let resourceClose, cleanupDuringReflection;
  const reflected = new Proxy([2], {ownKeys(target) {
    resourceClose = resourceKey.close();
    cleanupDuringReflection = api.collectionCleanups(221);
    return Reflect.ownKeys(target);
  }});
  let mixedResult, mixedError;
  try {mixedResult = api.mixedResourceEntries(new Map([[resourceKey, reflected]]));} catch (error) {mixedError = error;}
  assert.equal(cleanupDuringReflection, 0, 'entry key remains leased during later value reflection');
  assert.equal(mixedError, undefined); assert.equal(mixedResult, 223);
  await resourceClose; assert.equal(api.collectionCleanups(221), 1);
  const closedKey = new api.ResourceItem(222); await closedKey.close();
  let reflectedAfterClose = 0;
  const unread = new Proxy([2], {ownKeys(target) {reflectedAfterClose++; return Reflect.ownKeys(target);}});
  assert.throws(() => api.mixedResourceEntries(new Map([[closedKey, unread]])), /clos/i);
  assert.equal(reflectedAfterClose, 0, 'closed entry key rejects before reading its value');
  const live = new Uint8Array([3]), bytes = new Uint8Array([2]);
  const item = {text: '雪\ud800\0', values: [1, null], bytes: new Map([['key', bytes]]), shared: {key: live}};
  const source = [item, null], map = new Map([['key', item], ['nil', null]]);
  const box = new api.StructuralCollections(source, map);
  assert.equal(box.array(), source); assert.equal(box.map(), map); assert(box.independentReads());
  const a = box.read(0), b = box.read(0), entry = box.first();
  assert.notEqual(a, item); assert.notEqual(a.values, b.values); assert.notEqual(a.bytes, b.bytes);
  assert.notEqual(a.bytes.get('key').buffer, b.bytes.get('key').buffer);
  assert.notEqual(entry, item); assert.notEqual(entry.values, a.values);
  assert.equal(a.text, item.text); assert.equal(a.shared.key, live);
  a.shared.key[0] = 4; assert.equal(live[0], 4);
  a.values[0] = 8; a.bytes.get('key')[0] = 9;
  assert.equal(item.values[0], 1); assert.equal(bytes[0], 2);
  assert.equal(box.read(1), null); assert.equal(box.get('nil'), null); assert.equal(box.get('absent'), null);
  box.save(0); item.values[0] = 5; bytes[0] = 6;
  assert.equal(box.saved().values[0], 1); assert.equal(box.saved().bytes.get('key')[0], 2);
  box.change(7); box.writeSaved(2); box.writeSaved(3); box.putSaved('copy');
  assert.notEqual(source[2], source[3]); assert.notEqual(source[2].values, source[3].values);
  assert.notEqual(source[2].bytes.get('key').buffer, source[3].bytes.get('key').buffer);
  assert.equal(source[2].shared.key, live); assert.equal(map.get('copy').shared.key, live);
  box.change(8); assert.equal(source[2].values[0], 7); assert.equal(source[2].bytes.get('key')[0], 7);
  box.unsafe(); assert.throws(() => box.writeSaved(2), RangeError);
  assert.equal(source[2].values[0], 7); assert(box.catchesWrite(2));
  let sets = 0;
  Object.defineProperty(source, '4', {set() {sets++;}});
  assert(box.catchesWrite(4)); assert.equal(sets, 0);

  let getters = 0;
  const accessor = []; Object.defineProperty(accessor, '0', {get() {getters++; return 1;}});
  for (const [values, error] of [[[undefined], TypeError], [new Array(1), TypeError], [accessor, TypeError], [[2 ** 53], RangeError], [Array(10000).fill(1), RangeError]]) {
    const input = [{...item, values}], invalid = new api.StructuralCollections(input, new Map());
    assert.equal(invalid.array(), input); assert(invalid.catches(0));
    assert.throws(() => invalid.read(0), error);
  }
  assert.equal(getters, 0);
  const reason = Symbol('structural reflection');
  const proxy = new Proxy([1], {ownKeys() {throw reason;}});
  const proxied = new api.StructuralCollections([{...item, values: proxy}], new Map());
  exact(() => proxied.read(0), reason); assert(proxied.catches(0));
  const detached = new Uint8Array([1]); structuredClone(detached.buffer, {transfer: [detached.buffer]});
  assert.throws(() => new api.StructuralCollections([{...item, bytes: new Map([['key', detached]])}], new Map()).read(0), TypeError);
  const keys = new Map([[[1], {value: 2}]]), originalKey = [...keys.keys()][0], originalValue = keys.get(originalKey);
  assert(api.structuralKeys(keys)); assert.equal(keys.size, 2);
  assert.equal(keys.get(originalKey), originalValue); assert.deepEqual(originalKey, [1]); assert.equal(originalValue.value, 2);
  const [keyCopy, valueCopy] = [...keys][1]; assert.deepEqual(keyCopy, [1]); assert.equal(valueCopy.value, 2);
  const equalRecords = new Map([[{id: 1}, [1]], [{id: 1}, [2]]]);
  assert.deepEqual(api.recordKey(equalRecords), [1]); assert.equal(equalRecords.size, 2);
  const mapKey = new Map([['key', 1]]), dictKey = {key: 2};
  const mapKeys = new Map([[mapKey, {value: 3}]]), dictKeys = new Map([[dictKey, [4]]]);
  assert(api.containerKeys(mapKeys, dictKeys)); assert.equal(mapKeys.size, 2); assert.equal(dictKeys.size, 2);
  assert.equal(mapKey.get('key'), 1); assert.equal(dictKey.key, 2);
  const [newMapKey, newMapValue] = [...mapKeys][1], [newDictKey, newDictValue] = [...dictKeys][1];
  assert.notEqual(newMapKey, mapKey); assert.notEqual(newDictKey, dictKey);
  assert.equal(newMapKey.get('key'), 1); assert.equal(newMapValue.value, 3);
  assert.equal(newDictKey.key, 2); assert.deepEqual(newDictValue, [4]);
  const collision = [new Map([[{id: 1}, 1], [{id: 1}, 2]])];
  assert(api.recordMapCollision(collision, true));
  assert.throws(() => api.recordMapCollision(collision, false), TypeError);
  const big = [[1n << 62n]]; assert.equal(api.structuralBigints(big), big);
  assert.throws(() => api.structuralBigints([[1]]), TypeError);
  assert.throws(() => api.structuralBigints([[1n << 63n]]), RangeError);
  for (const [target, name, replacement] of [[BigInt.prototype, 'toString', function() {return '7';}], [globalThis, 'BigInt', () => 7n]]) {
    const original = target[name];
    try {
      target[name] = replacement;
      const ints = [[1n << 62n]], wide = [[1n << 130n]];
      api.structuralBigints(ints); api.structuralWideBigints(wide);
      assert.deepEqual(ints, [[1n << 62n]]); assert.deepEqual(wide, [[1n << 130n]]);
    } finally {target[name] = original;}
  }
  const callbackInput = [[11]];
  const callbackOutput = api.structuralCallback(value => {assert.equal(value, callbackInput); return value;}, callbackInput);
  callbackInput[0][0] = 12; assert.deepEqual(callbackOutput, [11]);
}
async function copiedPayloads(api) {
  const reference = new api.RefItem(31), handle = [undefined];
  for (const payload of [null, undefined, Symbol('copied')]) {
    const source = [{reference, payload, handle}], box = new api.CopiedPayloads(source);
    assert.equal(box.source(), source); assert(box.load(0));
    const output = box.saved(); assert.notEqual(output, source[0]);
    assert.equal(output.reference, reference); assert.equal(output.payload, payload); assert.equal(output.handle, handle);
    box.write(1); assert.notEqual(source[0], source[1]); assert.equal(source[1].handle, handle);
    assert.equal(box.payload(), payload); assert.equal(box.reference(), reference); assert.equal(box.handle(), handle);
  }
  let payload = {kept: true}; const weak = new WeakRef(payload);
  const source = [{reference, payload, handle}], box = new api.CopiedPayloads(source);
  assert(box.load(0)); source.length = 0; payload = null;
  for (let i = 0; i < 4; i++) {await tick(); api.pressure(i); global.gc();}
  assert.equal(box.payload(), weak.deref()); assert(weak.deref());
  assert.equal(box.handle(), handle); assert.equal(box.readInner(0), undefined);
  let failed = {failed: true}; const failedWeak = new WeakRef(failed);
  source[0] = {reference: {}, payload: failed, handle};
  assert.throws(() => box.load(0), TypeError); source.length = 0; failed = null;
  await collect(api, () => failedWeak.deref() === undefined);
  assert.equal(box.handle(), handle); assert.equal(box.readInner(0), undefined);
  box.clear(); await collect(api, () => weak.deref() === undefined);
  source[0] = {reference, payload: undefined, handle}; assert(box.load(0)); assert.equal(box.handle(), handle);
}

async function copiedResources(api) {
  const resource = new api.ResourceItem(401); let closing, during;
  const values = new Proxy([1], {ownKeys(target) {
    closing = resource.close(); during = api.collectionCleanups(401); return Reflect.ownKeys(target);
  }});
  const holder = new api.CopiedResources([{resource, values}]), pending = holder.hold(41);
  await until(() => api.collectionWaiting(41), 'expected copied resource Future gate');
  assert.equal(during, 0); assert.equal(api.collectionCleanups(401), 0);
  api.collectionComplete(41); assert.equal(await pending, 401); await closing;

  const saved = new api.ResourceItem(402), source = [{resource: saved, values: [1]}];
  const retained = new api.CopiedResources(source); retained.load();
  let setterClose, setterCount = 0;
  Object.defineProperty(source, '0', {set(value) {
    setterCount++; assert.equal(value.resource, saved);
    setterClose = saved.close(); assert.equal(api.collectionCleanups(402), 0);
  }});
  retained.write(); await setterClose; assert.equal(api.collectionCleanups(402), 1);
  assert.throws(() => retained.write(), /clos/i); assert.equal(setterCount, 1);

  for (const kind of [0, 1, 2]) {
    const id = 410 + kind, item = new api.ResourceItem(id);
    const outputHolder = new api.CopiedResources([{resource: item, values: [1]}]); outputHolder.load();
    const target = []; let cleanup;
    outputHolder.output(target, kind, () => {
      cleanup = item.close(); assert.equal(api.collectionCleanups(id), 0, 'reference retained before later Dart container getter');
    });
    assert.equal(target[0].$1, item); await cleanup; assert.equal(api.collectionCleanups(id), 1);
  }
  for (const dictionary of [false, true]) {
    const id = dictionary ? 414 : 413, item = new api.ResourceItem(id);
    const outputHolder = new api.CopiedResources([{resource: item, values: [1]}]); outputHolder.load();
    const maps = [], dictionaries = []; let cleanup;
    outputHolder.outputEntries(maps, dictionaries, dictionary, () => {
      cleanup = item.close(); assert.equal(api.collectionCleanups(id), 0, 'earlier Map/Dictionary entry already retains its resource');
    });
    if (dictionary) assert.equal(dictionaries[0].first, item);
    else assert.equal(maps[0].get(item), item);
    await cleanup; assert.equal(api.collectionCleanups(id), 1);
  }

  const timed = new api.ResourceItem(420), timers = new api.CopiedResources([{resource: timed, values: [1]}]);
  timers.load();
  for (const write of [false, true]) {
    timers.timer(write); await new Promise(resolve => setTimeout(resolve, 5));
    await until(() => api.collectionTimerResult().length === 1, 'expected detached copied resource access');
    assert.deepEqual(api.collectionTimerResult(), [1]);
  }
  await timed.close();

  const streamed = new api.ResourceItem(430); let streamClose, streamDuring;
  const streamValues = new Proxy([1], {ownKeys(target) {
    streamClose = streamed.close(); streamDuring = api.collectionCleanups(430); return Reflect.ownKeys(target);
  }});
  const streamHolder = new api.CopiedResources([{resource: streamed, values: streamValues}]);
  const stream = streamHolder.watch(44), read = stream.next();
  await until(() => api.collectionWaiting(44), 'expected copied stream read gate'); api.collectionComplete(44);
  await until(() => api.collectionWaiting(-44), 'expected copied resource stream cancellation');
  assert.equal(streamDuring, 0); assert.equal(api.collectionCleanups(430), 0);
  api.collectionComplete(-44); await streamClose; assert.equal((await read).done, true); await stream.return();
}

async function pureCopied(api) {
  const payload = {pure: true}, source = [[payload, undefined, null]];
  assert.equal(api.pureCopiedPayload(source), source); assert.notEqual(source[0], source[1]);
  assert.equal(source[1][0], payload); assert.equal(source[1][1], undefined); assert.equal(source[1][2], null);
}
async function valueClasses(api) {
  const item = {value: 3}, key = {value: 4}, mapped = {value: 5};
  const values = [item, {value: 6, tag: null}, null], map = new Map([[key, mapped]]), outputs = [null];
  const owner = new api.ValueCollectionOwner(values, map, outputs);
  assert.equal(owner.values(), values);
  assert.deepEqual(owner.read(0), {value: 3, tag: 7});
  assert.deepEqual(owner.read(1), {value: 6, tag: null});
  assert.equal(owner.read(2), null); assert.equal(owner.read(100), null);
  owner.copy(3); assert.notEqual(values[3], item); assert.deepEqual(values[3], {value: 3, tag: 7});
  assert.deepEqual(item, {value: 3});
  assert(owner.copiedKey()); assert.equal(map.size, 2); assert.equal(map.get(key), mapped);
  assert.notEqual([...map.keys()][1], key); assert.deepEqual([...map][1], [{value: 4, tag: 7}, {value: 5, tag: 7}]);
  assert.deepEqual(owner.readList([[{value: 8}]]), [{value: 8, tag: 7}]);
  assert.throws(() => owner.readList([[{value: 'bad'}]]), TypeError);
  assert.throws(() => owner.readMap([new Map([[{value: 1}, 1], [{value: 1, tag: 2}, 2]])]), TypeError);
  const parsed = [{source: '17'}]; assert.equal(owner.parsed(parsed), 17);
  owner.writeParsed(parsed); assert.deepEqual(parsed[0], {value: 19, doubled: 38});
  assert.throws(() => owner.parsed(parsed), TypeError);
  assert.equal(owner.readOutput(0), null); assert.equal(owner.readOutput(99), null);
  owner.writeOutput(1); assert.deepEqual(outputs[1], {value: 17});
  assert.throws(() => owner.readOutput(1), /input constructor/);
  const circular = [], node = {value: 9, children: circular}; circular.push(node);
  assert.equal(owner.nodeChildren(circular), circular);
  owner.copyNode(circular); assert.notEqual(circular[1], node);
  assert.equal(circular[1].children, circular); assert.equal(circular[1].value, 9);
  const before = api.collectionValueConstructions();
  assert.throws(() => owner.envelope([{child: {value: 10}, tail: 'bad'}]), TypeError);
  assert.equal(api.collectionValueConstructions(), before);
  assert.equal(owner.envelope([{child: {value: 10}}]), 10);
  assert.equal(api.collectionValueConstructions(), before + 1);
  const escaped = [{value: 23}], failing = [{node: {value: 22, children: escaped}, fail: true}];
  assert.throws(() => owner.escape(failing), /collection constructor failed/);
  failing.length = 0; assert.equal(owner.escapedChild(), 23);
  const cleanups = api.collectionValueCleanups(), resource = new api.CollectionResource(31);
  owner.remember(resource);
  let closed;
  const target = [];
  owner.writeResource(target, () => {
    closed = resource.close();
    assert.equal(api.collectionValueCleanups(), cleanups);
  });
  assert.equal(target[0].resource, resource); assert.equal(target[0].value, 31);
  await closed; assert.equal(api.collectionValueCleanups(), cleanups + 1);
}
const cases = {valueClasses, copiedResources, copiedPayloads, direct, scalars, maps, accessors, admission, captures, futures, streams, retained, opaque, opaqueAsync, opaqueRetained, nested, nestedHandles, references, resourceCollections, resourceCollectionStreams, binaryCollections, sharedByteCollections, structuralCollections};
async function worker(held) {
  const thread = new Worker(new URL(import.meta.url), {workerData: {held}});
  await new Promise((resolve, reject) => {
    thread.once('error', reject);
    if (held) thread.once('message', resolve);
    else thread.once('exit', code => code === 0 ? resolve() : reject(Error(`worker ${code}`)));
  });
  if (held) await thread.terminate();
}
if (!isMainThread) {
  const api = await import('@napi/js-collections-fixture'); await direct(api); await retained(api); await opaque(api);
  const resource = new api.ResourceItem(301), resources = new api.ResourceCollections([resource], new Map());
  assert.equal(resources.read(0), resource);
  if (workerData.held) {globalThis.resourceUse = resources.hold(50, false); globalThis.resourceClose = resource.close();}
  else await resource.close();
  if (workerData.held) {api.remember([1]); api.rememberMap(new Map([['a', 1]])); api.iterate(); api.next(); globalThis.pending = api.hold([2]); globalThis.opaque = new api.ArrayPayloads([{held: true}]); globalThis.opaque.load(0); globalThis.opaquePending = globalThis.opaque.captured(60000); setInterval(() => {}, 1000); parentPort.postMessage('ready');}
} else if (process.argv[2]) {
  const name = process.argv[2];
  if (name === 'worker-only') {await worker(false); await worker(true);}
  else if (name === 'nested-only') {await nested(await import('@napi/js-collections-nested'));}
  else if (name === 'pure-only') {await pureCopied(await import('@napi/js-collections-copied'));}
  else {
    const api = await import('@napi/js-collections-fixture');
    if (name === 'external') {const other = await import('@napi/js-collections-external'); for (const test of Object.values(cases)) await test(other);}
    else if (name === 'workers-with-main') {await direct(api); await worker(false); await worker(true); await direct(api);}
    else await cases[name](api);
  }
} else {
  for (const name of [...Object.keys(cases), 'external', 'nested-only', 'pure-only', 'worker-only', 'workers-with-main']) {
    const result = spawnSync(process.execPath, ['--expose-gc', fileURLToPath(import.meta.url), name], {encoding: 'utf8', timeout: 30000});
    assert.ifError(result.error); assert.equal(result.status, 0, `${name}: ${result.stdout}\n${result.stderr}`);
    console.log(`JS collection handles: ${name} passed`);
  }
}
