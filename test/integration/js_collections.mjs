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
const cases = {direct, scalars, maps, accessors, admission, captures, futures, streams, retained};
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
  const api = await import('@napi/js-collections-fixture'); await direct(api); await retained(api);
  if (workerData.held) {api.remember([1]); api.rememberMap(new Map([['a', 1]])); api.iterate(); api.next(); globalThis.pending = api.hold([2]); setInterval(() => {}, 1000); parentPort.postMessage('ready');}
} else if (process.argv[2]) {
  const name = process.argv[2];
  if (name === 'worker-only') {await worker(false); await worker(true);}
  else {
    const api = await import('@napi/js-collections-fixture');
    if (name === 'external') {const other = await import('@napi/js-collections-external'); for (const test of Object.values(cases)) await test(other);}
    else if (name === 'workers-with-main') {await direct(api); await worker(false); await worker(true); await direct(api);}
    else await cases[name](api);
  }
} else {
  for (const name of [...Object.keys(cases), 'external', 'worker-only', 'workers-with-main']) {
    const result = spawnSync(process.execPath, ['--expose-gc', fileURLToPath(import.meta.url), name], {encoding: 'utf8', timeout: 30000});
    assert.ifError(result.error); assert.equal(result.status, 0, `${name}: ${result.stdout}\n${result.stderr}`);
    console.log(`JS collection handles: ${name} passed`);
  }
}
