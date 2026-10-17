import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {runInNewContext} from 'node:vm';
import {Worker, isMainThread, parentPort, workerData} from 'node:worker_threads';

const filename = fileURLToPath(import.meta.url);
const packageName = '@napi/binary-fixture';
const tick = () => new Promise(resolve => setImmediate(resolve));
const bytes = (...values) => new Uint8Array(values);
const contents = value => [...(value instanceof ArrayBuffer ? new Uint8Array(value) : value)];
function snapshot(value, expected) {
  assert.deepEqual(contents(value), expected);
  if (value instanceof Uint8Array) {
    assert.equal(value.byteOffset, 0);
    assert.equal(value.buffer.byteLength, value.byteLength);
    assert.equal(Object.getPrototypeOf(value), Uint8Array.prototype);
  } else {
    assert.equal(Object.getPrototypeOf(value), ArrayBuffer.prototype);
  }
  assert.equal((value.buffer ?? value).resizable, false);
}
async function staysPending(promise) {
  let settled = false;
  promise.then(() => settled = true, () => settled = true);
  for (let i = 0; i < 3; i++) await tick();
  assert.equal(settled, false);
}

async function direct(api) {
  const storage = bytes(90, 1, 2, 3, 91);
  const input = storage.subarray(1, 4);
  const a = api.bytes(input), b = api.bytes(input);
  snapshot(a, [1, 2, 3]); snapshot(b, [1, 2, 3]);
  assert.notEqual(a, input); assert.notEqual(a.buffer, storage.buffer);
  assert.notEqual(a, b); assert.notEqual(a.buffer, b.buffer);
  storage.fill(8); snapshot(a, [1, 2, 3]);
  a.fill(9); snapshot(b, [1, 2, 3]); assert.deepEqual(contents(storage), [8, 8, 8, 8, 8]);
  const source = bytes(4, 5).buffer;
  const result = api.buffer(source);
  snapshot(result, [4, 5]); assert.notEqual(result, source);
  new Uint8Array(source).fill(6); snapshot(result, [4, 5]);
  new Uint8Array(result).fill(7); assert.deepEqual(contents(source), [6, 6]);
  snapshot(api.window(), [1, 2, 3]);
  snapshot(api.windowBuffer(), [90, 1, 2, 3, 91]);
  const repeated = api.repeated();
  assert.notEqual(repeated[0], repeated[1]); assert.notEqual(repeated[0].buffer, repeated[1].buffer);
  repeated[0][0] = 77; snapshot(repeated[1], [1, 2, 3]); snapshot(api.window(), [1, 2, 3]);
  const repeatedBuffers = api.repeatedBuffers();
  assert.notEqual(repeatedBuffers[0], repeatedBuffers[1]);
  new Uint8Array(repeatedBuffers[0]).fill(8);
  snapshot(repeatedBuffers[1], [90, 1, 2, 3, 91]);
  const emptyA = api.empty(), emptyB = api.empty();
  snapshot(emptyA, []); snapshot(emptyB, []); assert.notEqual(emptyA.buffer, emptyB.buffer);
  snapshot(api.bytes(new Uint8Array(new ArrayBuffer(4), 4, 0)), []);
  snapshot(api.buffer(new ArrayBuffer(0)), []);
}

async function admission(api) {
  const foreign = runInNewContext('({bytes: new Uint8Array([1, 2]), buffer: new Uint8Array([3, 4]).buffer})');
  snapshot(api.bytes(foreign.bytes), [1, 2]); snapshot(api.buffer(foreign.buffer), [3, 4]);
  snapshot(api.bytes(Buffer.from([7, 8])), [7, 8]);
  const input = bytes(5, 6), raw = input.buffer;
  let reads = 0;
  for (const name of ['byteLength', 'byteOffset', 'buffer', 'length', 'constructor']) {
    Object.defineProperty(input, name, {get() { reads++; throw Error(`own ${name}`); }});
  }
  for (const name of ['byteLength', 'resizable', 'maxByteLength', 'constructor']) {
    Object.defineProperty(raw, name, {get() { reads++; throw Error(`own ${name}`); }});
  }
  Object.defineProperty(input, Symbol.iterator, {get() { reads++; throw Error('iterator'); }});
  snapshot(api.bytes(input), [5, 6]); snapshot(api.buffer(raw), [5, 6]); assert.equal(reads, 0);
  const count = api.entries();
  const wrong = [null, undefined, {}, [], [1], new Int8Array(1), new Uint8ClampedArray(1),
    new Uint16Array(1), new DataView(new ArrayBuffer(1)), new ArrayBuffer(1)];
  for (const value of wrong) assert.throws(() => api.bytes(value), TypeError);
  for (const value of [null, undefined, {}, [], bytes(1), new DataView(new ArrayBuffer(1))]) {
    assert.throws(() => api.buffer(value), TypeError);
  }
  let traps = 0;
  const handler = new Proxy({}, {get() { traps++; return () => { traps++; throw Error('proxy trap'); }; }});
  assert.throws(() => api.bytes(new Proxy(bytes(1), handler)), TypeError);
  const revokedView = Proxy.revocable(bytes(1), {}); revokedView.revoke();
  assert.throws(() => api.bytes(revokedView.proxy), TypeError);
  const revoked = Proxy.revocable(new ArrayBuffer(1), {}); revoked.revoke();
  assert.throws(() => api.buffer(revoked.proxy), TypeError); assert.equal(traps, 0);
  const detached = bytes(1, 2), detachedBuffer = detached.buffer;
  structuredClone(detachedBuffer, {transfer: [detachedBuffer]});
  assert.throws(() => api.bytes(detached), TypeError);
  assert.throws(() => api.buffer(detachedBuffer), TypeError);
  const detachedEmpty = new ArrayBuffer(0);
  structuredClone(detachedEmpty, {transfer: [detachedEmpty]});
  assert.throws(() => api.buffer(detachedEmpty), TypeError);
  assert.throws(() => api.packet({bytes: bytes(1), data: detachedBuffer}), TypeError);
  assert.equal(api.entries(), count);
  const opaque = new Proxy(bytes(1), handler);
  assert.equal(api.opaque(opaque), opaque); assert.equal(api.opaque(detachedBuffer), detachedBuffer);
  assert.equal(traps, 0);
}

async function resizable(api) {
  const rab = new ArrayBuffer(8, {maxByteLength: 16});
  new Uint8Array(rab).set([90, 1, 2, 3, 4, 5, 6, 91]);
  const fixed = new Uint8Array(rab, 1, 3), tracking = new Uint8Array(rab, 2);
  snapshot(api.bytes(fixed), [1, 2, 3]); snapshot(api.bytes(tracking), [2, 3, 4, 5, 6, 91]);
  snapshot(api.buffer(rab), [90, 1, 2, 3, 4, 5, 6, 91]);
  rab.resize(5); snapshot(api.bytes(tracking), [2, 3, 4]);
  rab.resize(3); assert.throws(() => api.bytes(fixed), TypeError);
  snapshot(api.bytes(tracking), [2]); snapshot(api.buffer(rab), [90, 1, 2]);
  const zero = new Uint8Array(rab, 3, 0);
  snapshot(api.bytes(zero), []); rab.resize(2);
  assert.throws(() => api.bytes(zero), TypeError);
  snapshot(api.bytes(tracking), []); rab.resize(1);
  assert.throws(() => api.bytes(tracking), TypeError);
  rab.resize(0); snapshot(api.buffer(rab), []);
  for (const shared of [new SharedArrayBuffer(4), new SharedArrayBuffer(4, {maxByteLength: 8})]) {
    assert.throws(() => api.buffer(shared), TypeError);
    assert.throws(() => api.bytes(new Uint8Array(shared)), TypeError);
    assert.equal(api.opaque(shared), shared);
  }
}

async function presence(api) {
  assert.equal(api.nullable(null), null);
  assert.throws(() => api.nullable(), TypeError);
  assert.throws(() => api.nullable(undefined), TypeError);
  for (const args of [[], [undefined], [null]]) snapshot(api.optional(...args), [7]);
  snapshot(api.optional(bytes(8)), [8]);
  assert.deepEqual(api.named(), [null, null]); assert.deepEqual(api.named(undefined), [null, null]);
  assert.deepEqual(api.named({value: undefined, other: undefined}), [null, null]);
  const mixed = api.named({value: bytes(1), other: bytes(2).buffer});
  snapshot(mixed[0], [1]); snapshot(mixed[1], [2]);
  assert.throws(() => api.named(null), TypeError);
  for (const options of [undefined, {}, {value: undefined}, {value: null}]) {
    assert.throws(() => api.requiredNamed(options), TypeError);
  }
  snapshot(api.requiredNamed({value: bytes(9)}), [9]);
}

async function structural(api) {
  const input = bytes(1, 2), raw = bytes(3, 4).buffer;
  const list = api.lists([input, null, input]);
  snapshot(list[0], [1, 2]); assert.equal(list[1], null);
  assert.notEqual(list[0].buffer, list[2].buffer);
  const map = api.maps(new Map([[input, raw]]));
  const [[key, value]] = map;
  snapshot(key, [1, 2]); snapshot(value, [3, 4]); assert.notEqual(key, input);
  const dict = api.dictionary({one: input, two: input});
  assert.equal(Object.getPrototypeOf(dict), null); snapshot(dict.one, [1, 2]);
  assert.notEqual(dict.one.buffer, dict.two.buffer);
  const record = api.record({$1: input, data: raw});
  snapshot(record.$1, [1, 2]); snapshot(record.data, [3, 4]);
  const packet = api.packet({bytes: input, data: raw});
  snapshot(packet.bytes, [1, 2]); snapshot(packet.data, [3, 4]);
  input.fill(9); new Uint8Array(raw).fill(8);
  snapshot(list[0], [1, 2]); snapshot(value, [3, 4]); snapshot(packet.bytes, [1, 2]);
  assert.throws(() => api.lists([new Uint16Array(1)]), TypeError);
  assert.throws(() => api.dictionary({one: new Uint16Array(1)}), TypeError);
  assert.throws(() => api.record({$1: bytes(1), data: bytes(1)}), TypeError);
}

async function ordering(api) {
  const a = bytes(1), b = bytes(2), c = bytes(3), d = bytes(4);
  let calls = 0;
  api.setConversion(() => { calls++; a[0] = 11; b[0] = 12; c[0] = 13; d[0] = 14; });
  try {
    const values = api.packets([{bytes: a, data: b.buffer}, {bytes: c, data: d.buffer}]);
    assert.equal(calls, 2);
    snapshot(values[0].bytes, [1]); snapshot(values[0].data, [2]);
    snapshot(values[1].bytes, [3]); snapshot(values[1].data, [4]);
    a[0] = 1; b[0] = 2; c[0] = 3;
    const separate = api.afterPacket({bytes: a, data: b.buffer}, c);
    snapshot(separate[0], [1]); snapshot(separate[1], [13]);
    const first = new api.BinaryKey(1), second = new api.BinaryKey(2);
    a[0] = 1; c[0] = 3;
    const beforeHash = calls;
    const keyed = api.keyed(new Map([[first, a], [second, c]]));
    assert(calls > beforeHash, 'Map materialization must exercise Dart hashCode reentry');
    assert.equal(keyed.size, 2); snapshot(keyed.get(first), [1]); snapshot(keyed.get(second), [3]);
  } finally { api.setConversion(null); }
}

async function retained(api) {
  const input = bytes(1, 2), raw = bytes(3, 4).buffer;
  const box = new api.BinaryBox(input, raw);
  input.fill(8); new Uint8Array(raw).fill(9);
  snapshot(box.bytes, [1, 2]); snapshot(box.data, [3, 4]);
  const a = box.bytes, b = box.bytes; a.fill(7);
  snapshot(b, [1, 2]); snapshot(box.bytes, [1, 2]);
  box.change(5); snapshot(a, [7, 7]); snapshot(b, [1, 2]); snapshot(box.bytes, [5, 2]);
  const replacement = bytes(6); box.bytes = replacement; replacement[0] = 9;
  snapshot(box.bytes, [6]); box.data = null; assert.equal(box.data, null);
  let retainedBox;
  const weak = (() => {
    const value = bytes(1, 2, 3);
    retainedBox = new api.BinaryBox(value);
    return new WeakRef(value);
  })();
  for (let i = 0; i < 150 && weak.deref(); i++) { await tick(); api.pressure(); global.gc(); }
  assert.equal(weak.deref(), undefined, 'Dart storage must not retain the original JS input');
  snapshot(retainedBox.bytes, [1, 2, 3]);
}

async function futures(api) {
  const input = bytes(1, 2), promise = api.hold(1, input);
  assert(promise instanceof Promise); input.fill(9); await staysPending(promise);
  api.complete(1); const value = await promise; snapshot(value, [1, 2]);
  value.fill(8); assert.deepEqual(contents(input), [9, 9]);
  const raw = bytes(3, 4).buffer, future = api.futureBuffer(raw);
  new Uint8Array(raw).fill(7); snapshot(await future, [3, 4]);
  const output = await api.futureWindow(); snapshot(output, [1, 2, 3]);
  const rows = await api.futureRows(); snapshot(rows[0], [1, 2, 3]);
  rows[0].fill(8); snapshot(rows[1], [1, 2, 3]);
  api.changeOutput(44); snapshot(output, [1, 2, 3]); snapshot(await api.futureWindow(), [44, 2, 3]);
  const failed = api.hold(2, bytes(1)); api.complete(2, {fail: true});
  await assert.rejects(failed, /binary-failure:2/);
  await assert.rejects(api.hold(3, new Uint16Array(1)), TypeError);
}

async function streams(api) {
  const owner = new api.BinaryOwner(1), iterator = owner.values, buffers = owner.buffers, rows = owner.rows;
  assert.equal(iterator[Symbol.asyncIterator](), iterator);
  const first = iterator.next(), raw = buffers.next(), row = rows.next(); owner.emit(1);
  snapshot((await first).value, [1, 2]); snapshot((await raw).value, [90, 1, 2, 91]);
  const nested = (await row).value; snapshot(nested[0], [1, 2]);
  nested[0].fill(9); snapshot(nested[1], [1, 2]); await rows.return();
  owner.emit(3); owner.emit(5);
  const a = (await iterator.next()).value, b = (await iterator.next()).value;
  snapshot(a, [3, 4]); snapshot(b, [5, 6]); a.fill(8); snapshot(b, [5, 6]);
  snapshot((await buffers.next()).value, [90, 3, 4, 91]);
  await buffers.return(); await iterator.return(); await owner.close();
  assert.equal(api.events().filter(value => value === 'cleanup:1').length, 1);
}

async function resources(api) {
  const owner = new api.BinaryOwner(7), source = bytes(1, 2);
  const future = owner.work(70, source), close = owner.close();
  source.fill(8); await staysPending(close);
  assert.equal(api.events().includes('cleanup:7'), false);
  api.complete(70); snapshot(await future, [1, 2]); await close;
  assert.equal(api.events().filter(value => value === 'cleanup:7').length, 1);
  const feed = new api.BinaryOwner(8), iterator = feed.values;
  const accepted = iterator.next(); feed.emit(4); const closed = feed.close();
  snapshot((await accepted).value, [4, 5]); await closed;
  assert.equal((await iterator.next()).done, true);
  const events = api.events();
  assert(events.indexOf('cancel-bytes:8') < events.indexOf('cleanup:8'));
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
  const tests = {direct, admission, resizable, presence, structural, ordering, retained, futures, streams, resources};
  if (name === 'external') {
    const external = await import('@napi/binary-external');
    await direct(external); await admission(external); await structural(external);
    await ordering(external); await futures(external); await streams(external);
  } else if (name === 'workers-with-main') {
    snapshot(api.bytes(bytes(1)), [1]); await worker(false); await worker(true); await worker(true);
    snapshot(api.bytes(bytes(2)), [2]);
  } else if (name === 'implicit-exit') {
    globalThis.pending = api.hold(100, new Uint8Array(65536));
    globalThis.owner = new api.BinaryOwner(100);
    globalThis.iterator = globalThis.owner.values;
    globalThis.read = globalThis.iterator.next();
  } else { assert(tests[name]); await tests[name](api); }
}
if (!isMainThread) {
  const api = await import(packageName); await direct(api); await retained(api);
  if (workerData.held) {
    globalThis.pending = api.hold(100, new Uint8Array(65536));
    globalThis.owner = new api.BinaryOwner(100);
    globalThis.iterator = globalThis.owner.values;
    globalThis.read = globalThis.iterator.next();
    setInterval(() => {}, 1000); parentPort.postMessage('ready');
  }
} else if (process.argv[2]) {
  await scenario(process.argv[2]);
} else {
  const cases = ['direct', 'admission', 'resizable', 'presence', 'structural', 'ordering',
    'retained', 'futures', 'streams', 'resources', 'external', 'implicit-exit', 'worker-only', 'workers-with-main'];
  for (const name of cases) {
    const result = spawnSync(process.execPath, ['--expose-gc', filename, name], {
      encoding: 'utf8', timeout: 30_000, maxBuffer: 4 * 1024 * 1024,
    });
    assert.ifError(result.error);
    assert.equal(result.signal, null, `${name}: ${result.stderr}`);
    assert.equal(result.status, 0, `${name}: ${result.stdout}\n${result.stderr}`);
    console.log(`Binary contract: ${name} passed`);
  }
  console.log(`Binary contract: ${cases.length} fresh-process scenarios passed`);
}
