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
const cases = {direct, scalars, maps, accessors, admission, captures, futures, streams, retained, opaque, opaqueAsync, opaqueRetained, nested, nestedHandles};
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
  if (workerData.held) {api.remember([1]); api.rememberMap(new Map([['a', 1]])); api.iterate(); api.next(); globalThis.pending = api.hold([2]); globalThis.opaque = new api.ArrayPayloads([{held: true}]); globalThis.opaque.load(0); globalThis.opaquePending = globalThis.opaque.captured(60000); setInterval(() => {}, 1000); parentPort.postMessage('ready');}
} else if (process.argv[2]) {
  const name = process.argv[2];
  if (name === 'worker-only') {await worker(false); await worker(true);}
  else if (name === 'nested-only') {await nested(await import('@napi/js-collections-nested'));}
  else {
    const api = await import('@napi/js-collections-fixture');
    if (name === 'external') {const other = await import('@napi/js-collections-external'); for (const test of Object.values(cases)) await test(other);}
    else if (name === 'workers-with-main') {await direct(api); await worker(false); await worker(true); await direct(api);}
    else await cases[name](api);
  }
} else {
  for (const name of [...Object.keys(cases), 'external', 'nested-only', 'worker-only', 'workers-with-main']) {
    const result = spawnSync(process.execPath, ['--expose-gc', fileURLToPath(import.meta.url), name], {encoding: 'utf8', timeout: 30000});
    assert.ifError(result.error); assert.equal(result.status, 0, `${name}: ${result.stdout}\n${result.stderr}`);
    console.log(`JS collection handles: ${name} passed`);
  }
}
