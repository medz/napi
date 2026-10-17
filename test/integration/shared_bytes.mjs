import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {runInNewContext} from 'node:vm';
import {Worker, isMainThread, parentPort, workerData} from 'node:worker_threads';

const filename = fileURLToPath(import.meta.url);
const packageName = '@napi/shared-bytes-fixture';
const tick = () => new Promise(resolve => setImmediate(resolve));
const bytes = (...values) => new Uint8Array(values);
async function pending(promise) {
  let settled = false;
  promise.then(() => settled = true, () => settled = true);
  for (let i = 0; i < 4; i++) await tick();
  assert.equal(settled, false);
}
async function collect(api, predicate) {
  for (let i = 0; i < 60; i++) {
    await tick(); api.pressure(); global.gc(); await tick();
    if (predicate()) return;
  }
  assert(predicate(), 'expected released Dart adapter');
}

async function direct(api) {
  const storage = bytes(90, 1, 2, 3, 91), value = storage.subarray(1, 4);
  assert.equal(api.remember(value), value); assert(api.same(value));
  value[0] = 8; assert.equal(api.read(0), 8);
  api.put(1, 9); assert.equal(storage[2], 9);
  const view = api.view(1);
  assert.equal(view.buffer, storage.buffer); assert.equal(view.byteOffset, 2);
  view[0] = 10; assert.equal(api.read(1), 10);
  const snapshot = api.snapshot(); value[0] = 11;
  assert.deepEqual([...snapshot], [8, 10, 3]); assert.notEqual(snapshot.buffer, storage.buffer);
  api.write(bytes(21, 22), 1); assert.deepEqual([...value], [11, 21, 22]);
  api.copy(value, 0, 1, 2); assert.deepEqual([...value], [11, 11, 21]);
  api.copy(value.subarray(1), 0, 0, null); assert.deepEqual([...value], [11, 21, 21]);
  const unchanged = [...value];
  for (const action of [() => api.read(-1), () => api.read(2 ** 32), () => api.put(0, 256),
    () => api.view(0, -1), () => api.snapshot(4), () => api.copy(value, 0, 1, 3),
    () => api.write(bytes(1, 2, 3), 1), () => api.allocate(-1), () => api.allocate(2 ** 32)]) {
    assert.throws(action, RangeError);
  }
  assert.deepEqual([...value], unchanged);
  const allocated = api.allocate(3); assert.deepEqual([...allocated], [0, 0, 0]);
  assert.equal(Object.hasOwn(allocated, 'length'), false);
  assert.equal(Object.hasOwn(allocated.buffer, 'byteLength'), false);
  const box = new api.SharedBox(value); box.change(31); assert.equal(value[0], 31);
  box.bytes = allocated; assert.equal(box.bytes, allocated);
  assert.deepEqual([...api.SharedBox.allocated(2).bytes], [0, 0]);
  const foreign = runInNewContext('new Uint8Array(new ArrayBuffer(8), 3, 2)');
  assert.equal(api.remember(foreign), foreign); api.put(0, 41); assert.equal(foreign[0], 41);
  const buffer = Buffer.from([1, 2]); assert.equal(api.remember(buffer), buffer);
}

async function admission(api) {
  assert.throws(() => api.fakeOutput(), TypeError);
  api.remember(bytes(1)); assert.throws(() => api.fakeCopy(), TypeError);
  const count = api.entries();
  for (const value of [null, undefined, {}, [], new Int8Array(1), new Uint8ClampedArray(1),
    new Uint16Array(1), new DataView(new ArrayBuffer(1)), new ArrayBuffer(1),
    new Uint8Array(new SharedArrayBuffer(1)), new Uint8Array(new SharedArrayBuffer(1, {maxByteLength: 2}))]) {
    assert.throws(() => api.remember(value), TypeError);
  }
  let traps = 0;
  const handler = new Proxy({}, {get() {traps++; throw Error('proxy');}});
  assert.throws(() => api.remember(new Proxy(bytes(1), handler)), TypeError);
  const revoked = Proxy.revocable(bytes(1), {}); revoked.revoke();
  assert.throws(() => api.remember(revoked.proxy), TypeError); assert.equal(traps, 0);
  assert.equal(api.entries(), count);
  const value = bytes(1, 2);
  for (const name of ['buffer', 'byteLength', 'byteOffset', 'length', 'constructor']) {
    Object.defineProperty(value, name, {get() {traps++; throw Error(name);}});
  }
  Object.defineProperty(value, Symbol.iterator, {get() {traps++; throw Error('iterator');}});
  assert.equal(api.remember(value), value); assert.equal(api.length(), 2);
  assert.deepEqual([...api.snapshot()], [1, 2]); assert.equal(traps, 0);
  const typed = Object.getPrototypeOf(Uint8Array.prototype), restores = [];
  const originalU8 = globalThis.Uint8Array;
  const replacement = function() { throw Error('replace constructor'); };
  Object.defineProperty(replacement, Symbol.hasInstance, {value: x => x instanceof originalU8});
  try {
    for (const [owner, names] of [[typed, ['length', 'buffer', 'byteOffset', 'byteLength', 'at', 'set']],
      [ArrayBuffer.prototype, ['byteLength']]]) {
      for (const name of names) {
        const descriptor = Object.getOwnPropertyDescriptor(owner, name);
        restores.push(() => Object.defineProperty(owner, name, descriptor));
        Object.defineProperty(owner, name, {configurable: true, get() {throw Error(name);}});
      }
    }
    globalThis.Uint8Array = replacement;
    assert.equal(api.length(), 2); api.put(0, 51);
    assert.equal(api.snapshot()[0], 51);
    api.write(new originalU8([52]), 1); assert.equal(api.read(1), 52);
    assert.equal(api.allocate(1)[0], 0);
  } finally {
    globalThis.Uint8Array = originalU8;
    for (const restore of restores.reverse()) restore();
  }
}

async function windows(api) {
  const rab = new ArrayBuffer(8, {maxByteLength: 16});
  const fixed = new Uint8Array(rab, 2, 4), tracking = new Uint8Array(rab, 2);
  api.remember(tracking); const sub = api.view(1);
  rab.resize(12); assert.equal(api.length(), 10); assert.equal(sub.length, 5);
  api.remember(fixed); rab.resize(3);
  assert.throws(() => api.length(), TypeError); assert.throws(() => api.read(0), TypeError);
  assert.equal(api.caught(), -1); assert.throws(() => api.remember(fixed), TypeError);
  rab.resize(8); assert.equal(api.length(), 4); api.put(0, 7); assert.equal(tracking[0], 7);
  const zero = new Uint8Array(rab, 8, 0); api.remember(zero); assert.equal(api.length(), 0);
  rab.resize(7); assert.throws(() => api.length(), TypeError);
  rab.resize(8); assert.equal(api.length(), 0);
  const empty = new Uint8Array(new ArrayBuffer(0)); api.remember(empty); assert.equal(api.length(), 0);
  structuredClone(empty.buffer, {transfer: [empty.buffer]}); assert.throws(() => api.length(), TypeError);
  const live = bytes(1); api.remember(live); const work = api.delayedRead();
  structuredClone(live.buffer, {transfer: [live.buffer]}); await assert.rejects(work, TypeError);
  const memory = new WebAssembly.Memory({initial: 1}); const old = new Uint8Array(memory.buffer);
  api.remember(old); memory.grow(1); assert.throws(() => api.read(0), TypeError);
}

async function structure(api) {
  const value = bytes(1);
  assert.equal(api.optional(), null); assert.equal(api.optional(undefined), null);
  assert.equal(api.optional(null), null); assert.equal(api.optional(value), value);
  assert.equal(api.nullable(null), null); assert.throws(() => api.nullable(undefined), TypeError);
  assert.equal(api.named(), null); assert.equal(api.named({value}), value);
  assert.equal(api.requiredNamed({value}), value);
  const list = api.lists([value, null, value]); assert.equal(list[0], value); assert.equal(list[2], value);
  const map = api.maps(new Map([[value, value]])); assert.equal(map.get(value), value);
  assert.equal(api.dictionary({one: value}).one, value);
  const row = api.record({$1: value, other: value}); assert.equal(row.$1, value); assert.equal(row.other, value);
  assert.equal(api.packet({bytes: value}).bytes, value);
  const count = api.entries(); api.drop();
  assert.throws(() => api.partial({bytes: value}, 'invalid'), TypeError);
  assert.equal(api.entries(), count);
  await collect(api, () => !api.alive());
}

async function ordering(api) {
  for (const cached of [false, true]) {
    const first = bytes(1), second = bytes(2);
    if (cached) api.remember(second);
    let calls = 0;
    api.setConversion(() => {
      if (++calls === 1) structuredClone(second.buffer, {transfer: [second.buffer]});
    });
    try {assert.equal(api.packets([{bytes: first}, {bytes: second}]), 2);}
    finally {api.setConversion(null);}
    assert.equal(calls, 2);
  }
  const rab = new ArrayBuffer(8, {maxByteLength: 16}), view = new Uint8Array(rab, 2, 4);
  api.remember(view); rab.resize(3);
  let calls = 0;
  api.setConversion(() => {calls++; rab.resize(8);});
  try {assert.equal(api.repairOutput().$1, view);}
  finally {api.setConversion(null);}
  assert.equal(calls, 1);
}

async function retained(api) {
  const value = bytes(61); const weakView = new WeakRef(value);
  api.remember(value);
  for (let i = 0; i < 4; i++) {await tick(); api.pressure(); global.gc(); await tick();}
  assert(api.alive()); assert.equal(api.read(0), 61); assert.equal(weakView.deref(), value);
  api.drop(); await collect(api, () => !api.alive());
  assert.equal(api.remember(value), value); assert(api.same(value));
  let transient = bytes(62); const released = new WeakRef(transient);
  api.remember(transient); transient = null; api.drop();
  await collect(api, () => released.deref() === undefined);
}

async function futures(api) {
  const value = bytes(1); const promise = api.hold(1, value);
  value[0] = 2; await pending(promise); api.complete(1);
  assert.equal(await promise, value); assert.equal(value[0], 2);
  const reason = {exact: true}; const hostile = bytes(3);
  Object.defineProperty(hostile, 'then', {get() {throw reason;}});
  const failure = api.hold(2, hostile); api.complete(2);
  await assert.rejects(failure, error => error === reason);
  const thenable = bytes(4); thenable.then = resolve => resolve('adopted');
  const assimilated = api.hold(3, thenable); api.complete(3); assert.equal(await assimilated, 'adopted');
  await assert.rejects(api.hold(4, new Uint16Array(1)), TypeError);
}

async function streams(api) {
  const owner = new api.SharedOwner(1), iterator = owner.values, rows = owner.rows;
  const value = bytes(1); Object.defineProperty(value, 'then', {get() {throw Error('item then');}});
  const accepted = iterator.next(), nested = rows.next(); owner.emit(value);
  const first = await accepted; assert.equal(first.value, value); assert.equal(first.value[0], 2);
  const row = (await nested).value; assert.equal(row[0], value); assert.equal(row[1], value);
  value[0] = 3; assert.equal(first.value[0], 3);
  const next = iterator.next(); owner.emit(value); const closed = owner.close();
  assert.equal((await next).value, value);
  await closed; assert.equal((await iterator.next()).done, true);
  const events = api.events(); assert(events.indexOf('cancel:1') < events.indexOf('cleanup:1'));
  assert.equal(events.filter(x => x === 'cleanup:1').length, 1);
}

async function resources(api) {
  const owner = new api.SharedOwner(2), value = bytes(1);
  const future = owner.work(20, value), close = owner.close();
  value[0] = 8; await pending(close);
  for (let i = 0; i < 4; i++) {await tick(); api.pressure(); global.gc(); await tick();}
  assert(!api.events().includes('cleanup:2'));
  api.complete(20); assert.equal(await future, value); await close;
  assert.equal(api.events().filter(x => x === 'cleanup:2').length, 1);
}

async function internal() {
  const api = await import('@napi/shared-bytes-internal');
  assert.equal(new api.Internal(2).value, 17); assert.equal(api.compute(0), 0);
  assert.equal(api.compute(2), 17); assert.equal(await api.later(2), 17);
  assert.equal(api.defaults(0), 0); assert.equal(api.defaults(4), 23);
  assert.equal(await api.laterDefaults(4), 23);
  assert.throws(() => api.compute(-1), RangeError); await assert.rejects(api.later(-1), RangeError);
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
const cases = {direct, admission, windows, structure, ordering, retained, futures, streams, resources};
async function scenario(name) {
  if (name === 'internal') return internal();
  if (name === 'worker-only') {await worker(false); await worker(true); return;}
  const api = await import(packageName);
  if (name === 'external') {
    const external = await import('@napi/shared-bytes-external');
    for (const test of Object.values(cases)) await test(external);
  } else if (name === 'workers-with-main') {
    await direct(api); await worker(false); await worker(true); await direct(api);
  } else if (name === 'implicit-exit') {
    globalThis.pending = api.hold(100, new Uint8Array(65536));
    globalThis.owner = new api.SharedOwner(100); globalThis.iterator = globalThis.owner.values;
    globalThis.read = globalThis.iterator.next();
  } else {assert(cases[name]); await cases[name](api);}
}
if (!isMainThread) {
  const api = await import(packageName); await direct(api); await retained(api); await internal();
  if (workerData.held) {
    globalThis.pending = api.hold(100, new Uint8Array(65536));
    globalThis.owner = new api.SharedOwner(100); globalThis.iterator = globalThis.owner.values;
    globalThis.read = globalThis.iterator.next();
    setInterval(() => {}, 1000); parentPort.postMessage('ready');
  }
} else if (process.argv[2]) {
  await scenario(process.argv[2]);
} else {
  for (const name of [...Object.keys(cases), 'internal', 'external', 'implicit-exit', 'worker-only', 'workers-with-main']) {
    const result = spawnSync(process.execPath, ['--expose-gc', filename, name], {
      encoding: 'utf8', timeout: 30_000, maxBuffer: 4 * 1024 * 1024,
    });
    assert.ifError(result.error); assert.equal(result.signal, null, `${name}: ${result.stderr}`);
    assert.equal(result.status, 0, `${name}: ${result.stdout}\n${result.stderr}`);
    console.log(`Shared bytes contract: ${name} passed`);
  }
}
