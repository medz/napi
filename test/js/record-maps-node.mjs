import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { setImmediate as immediate } from 'node:timers/promises';
import { runInNewContext } from 'node:vm';
import * as api from '@napi/record-maps';
import * as subpath from '@napi/record-maps/module.wasm';
import * as relative from './dist/module.wasm';

const names = [
  'echoUsers', 'echoUsersAsync', 'normalizeUsers',
  'echoNullableUsers', 'echoNullableUsersAsync',
  'echoNullableContainer', 'echoNullableContainerAsync',
  'echoNullableBoth', 'echoNullableBothAsync', 'echoAlias', 'echoAliasAsync',
  'echoInline', 'echoInlineAsync', 'echoMapOnly', 'echoMixed', 'echoSpecial',
  'echoPackets', 'echoPacketsAsync', 'echoNullablePackets', 'echoNullablePacketsAsync',
  'echoInlinePackets', 'echoByteFields', 'normalizePackets', 'normalizePacketsAsync',
  'calls', 'trackedPackets', 'trackedPacketsAsync', 'readPackets', 'changePackets',
  'badUsers', 'badUsersAsync',
];
for (const name of names) {
  assert.equal(typeof api[name], 'function', name);
  assert.equal(api[name], subpath[name], `${name} package subpath`);
  assert.equal(api[name], relative[name], `${name} relative Wasm`);
  assert.match(Function.prototype.toString.call(api[name]), /\[native code\]/, name);
}
for (const name of ['User', 'MaybeUserAlias', 'MapOnly', 'Packet', 'MaybePacket', 'ByteFields', 'Mixed', 'SpecialFields']) {
  assert.equal(Object.hasOwn(api, name), false, `${name} is a type-only alias`);
}

let checks = 0;
function invoke(name, ...args) {
  checks++;
  if (!name.endsWith('Async')) return api[name](...args);
  let promise;
  assert.doesNotThrow(() => { promise = api[name](...args); });
  assert(promise instanceof Promise, `${name} returns a genuine Promise`);
  return bounded(promise);
}
async function bounded(promise) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error('Record-map Promise did not settle')), 3000);
    })]);
  } finally {
    clearTimeout(timer);
  }
}
async function failure(name, args, type, context) {
  let caught;
  try { await invoke(name, ...args); } catch (error) { caught = error; }
  assert(caught instanceof type, `${name}: ${caught?.constructor?.name}: ${caught?.message}`);
  if (context) assert.equal(caught.message.split(context).length - 1, 1, `${name}: ${caught.message}`);
  return caught;
}
function dataObject(actual, expected) {
  assert.equal(Object.getPrototypeOf(actual), null);
  assert.deepEqual(Reflect.ownKeys(actual).sort(), Object.keys(expected).sort());
  for (const key of Object.keys(expected)) {
    const descriptor = Object.getOwnPropertyDescriptor(actual, key);
    assert(Object.hasOwn(descriptor, 'value'));
    assert.equal(descriptor.enumerable, true);
    assert.equal(descriptor.writable, true);
    assert.equal(descriptor.configurable, true);
  }
}
function equalRecord(actual, expected) {
  dataObject(actual, expected);
  for (const key of Object.keys(expected)) {
    if (expected[key] instanceof Uint8Array) {
      assert(actual[key] instanceof Uint8Array);
      assert.deepEqual(actual[key], new Uint8Array(expected[key]));
    } else assert(Object.is(actual[key], expected[key]), `${key} preserves its scalar value`);
  }
}
function equalMap(actual, expected) {
  dataObject(actual, expected);
  for (const key of Object.keys(expected)) {
    if (expected[key] === null) assert.equal(actual[key], null);
    else equalRecord(actual[key], expected[key]);
  }
}
const user = () => ({ name: '你好\ud800', age: 20, active: null });
const packet = payload => ({ name: 'packet', payload });
const unhandled = [];
const onUnhandled = reason => unhandled.push(reason);
process.on('unhandledRejection', onUnhandled);
process.on('uncaughtException', onUnhandled);
try {
  const keys = ['', '__proto__', 'constructor', 'prototype', 'then', 'a"b\\c', 'nul\0key', '你好\ud800', '\udfff'];
  const special = Object.fromEntries(keys.map(key => [key, user()]));
  for (const name of ['echoUsers', 'echoUsersAsync']) {
    equalMap(await invoke(name, {}), {});
    equalMap(await invoke(name, Object.freeze(special)), special);
    const frozen = Object.freeze({ alice: Object.freeze(user()) });
    equalMap(await invoke(name, frozen), frozen);
    for (const age of [0, -Number.MAX_SAFE_INTEGER, Number.MAX_SAFE_INTEGER]) {
      equalMap(await invoke(name, { alice: { ...user(), age } }), { alice: { ...user(), age } });
    }
    for (const age of [Number.MAX_SAFE_INTEGER + 1, -Number.MAX_SAFE_INTEGER - 1]) {
      await failure(name, [{ first: user(), 'a"b\\c': { ...user(), age } }], RangeError, 'parameter users["a\\"b\\\\c"]["age"]');
    }
    for (const age of [1.5, Infinity, NaN]) {
      await failure(name, [{ late: { ...user(), age } }], TypeError, 'parameter users["late"]["age"]');
    }
    for (const value of [null, undefined, [], new Map(), new Date(), Promise.resolve({}), new Uint8Array(), Object.create({})]) {
      await failure(name, [value], TypeError, 'parameter users');
    }
    for (const value of [null, undefined, [], { ...user(), age: '20' }, { ...user(), active: undefined }, { name: 'missing', age: 1 }, Object.create(user())]) {
      await failure(name, [{ first: user(), late: value }], TypeError, 'parameter users["late"]');
    }
    equalMap(await invoke(name, { recovered: user() }), { recovered: user() });
  }

  for (const suffix of ['', 'Async']) {
    equalMap(await invoke(`echoNullableUsers${suffix}`, { alice: user(), nobody: null }), { alice: user(), nobody: null });
    await failure(`echoNullableUsers${suffix}`, [null], TypeError, 'parameter users');
    equalMap(await invoke(`echoNullableContainer${suffix}`, { alice: user() }), { alice: user() });
    assert.equal(await invoke(`echoNullableContainer${suffix}`, null), null);
    await failure(`echoNullableContainer${suffix}`, [{ nobody: null }], TypeError, 'parameter users["nobody"]');
    equalMap(await invoke(`echoNullableBoth${suffix}`, { nobody: null, alice: user() }), { nobody: null, alice: user() });
    assert.equal(await invoke(`echoNullableBoth${suffix}`, null), null);
    equalMap(await invoke(`echoAlias${suffix}`, { nobody: null, alice: user() }), { nobody: null, alice: user() });
    for (const name of ['echoNullableUsers', 'echoNullableContainer', 'echoNullableBoth', 'echoAlias']) {
      await failure(name + suffix, [undefined], TypeError, 'parameter users');
      await failure(name + suffix, [{ late: undefined }], TypeError, 'parameter users["late"]');
    }
    const inline = { label: '\udfff', count: Number.MAX_SAFE_INTEGER, flag: null, score: -0 };
    equalMap(await invoke(`echoInline${suffix}`, { inline, nobody: null }), { inline, nobody: null });
    assert.equal(await invoke(`echoInline${suffix}`, null), null);
    await failure(`echoInline${suffix}`, [{ late: { ...inline, flag: undefined } }], TypeError, 'parameter values["late"]["flag"]');
  }
  equalMap(invoke('normalizeUsers', { ada: { name: ' Ada ', age: -1, active: null } }), { ada: { name: 'Ada', age: 0, active: false } });
  equalMap(invoke('echoMapOnly', { inline: { label: 'map only', score: Infinity } }), { inline: { label: 'map only', score: Infinity } });
  const mixed = { flag: true, count: 2, value: NaN, text: '\udfff', maybeFlag: false, maybeCount: null, maybeValue: -0, maybeText: null };
  equalMap(invoke('echoMixed', { mixed }), { mixed });
  const specialFields = { constructor: 'own', prototype: '\ud800', then: 'scalar', $value: -0 };
  equalMap(invoke('echoSpecial', { then: specialFields }), { then: specialFields });

  // Only map keys are enumerated. Declared record fields are own data properties,
  // including non-enumerable fields; ignored properties never run getters.
  let getterCalls = 0;
  for (const name of ['echoUsers', 'echoUsersAsync']) {
    const hiddenRow = Object.create(null);
    for (const [key, value] of Object.entries(user())) Object.defineProperty(hiddenRow, key, { value });
    const values = Object.assign(Object.create(null), { visible: hiddenRow });
    Object.defineProperty(values, 'hidden', { get() { getterCalls++; throw Error('ignored map getter'); } });
    Object.defineProperty(values, Symbol('ignored'), { enumerable: true, get() { getterCalls++; throw Error('ignored symbol getter'); } });
    equalMap(await invoke(name, values), { visible: user() });
    Object.defineProperty(values, 'bad', { enumerable: true, get() { getterCalls++; return user(); } });
    await failure(name, [values], TypeError, 'parameter users["bad"]');
    const accessor = user();
    Object.defineProperty(accessor, 'name', { get() { getterCalls++; return 'wrong'; } });
    await failure(name, [{ late: accessor }], TypeError, 'parameter users["late"]["name"]');
    const seen = [];
    const row = user();
    Object.defineProperty(row, 'ignored', { enumerable: true, get() { getterCalls++; throw Error('ignored record getter'); } });
    const proxyRow = new Proxy(row, {
      get() { throw Error('record values must use descriptors'); },
      ownKeys() { throw Error('record extras must not be enumerated'); },
      getOwnPropertyDescriptor(target, key) { seen.push(key); return Reflect.getOwnPropertyDescriptor(target, key); },
    });
    equalMap(await invoke(name, new Proxy({ alice: proxyRow }, { get() { throw Error('map values must use descriptors'); } })), { alice: user() });
    assert.deepEqual(seen.sort(), ['active', 'age', 'name']);
    const foreign = runInNewContext("({['\\udfff']:{name:'你好\\ud800',age:20,active:null}})");
    equalMap(await invoke(name, foreign), { '\udfff': user() });
    for (const reason of [new Error('reflection'), new TypeError('reflection type'), 'thrown string', Symbol('reason')]) {
      for (const input of [
        new Proxy({ alice: user() }, { ownKeys() { throw reason; } }),
        { alice: new Proxy(user(), { getOwnPropertyDescriptor() { throw reason; } }) },
      ]) {
        let caught = false;
        try { await invoke(name, input); } catch (error) { caught = true; assert.equal(error, reason); }
        assert(caught);
      }
    }
  }
  assert.equal(getterCalls, 0);

  // New Map/record layers must preserve the established byte-copy boundary.
  for (const name of ['echoPackets', 'echoPacketsAsync']) {
    const backing = Buffer.from([99, 0, 128, 255, 88]);
    const bytes = backing.subarray(1, 4);
    const row = packet(bytes);
    const output = await invoke(name, { first: row, again: row });
    equalMap(output, { first: packet(new Uint8Array([0, 128, 255])), again: packet(new Uint8Array([0, 128, 255])) });
    assert.notEqual(output.first, output.again);
    assert.notEqual(output.first.payload.buffer, output.again.payload.buffer);
    assert.notEqual(output.first.payload.buffer, bytes.buffer);
    output.first.payload[0] = 7; output.first.name = 'changed';
    assert.equal(output.again.payload[0], 0); assert.equal(bytes[0], 0);
    equalMap(await invoke(name, { empty: packet(new Uint8Array()) }), { empty: packet(new Uint8Array()) });
    const foreign = runInNewContext("({foreign:{name:'packet',payload:new Uint8Array([0,128,255])}})");
    equalMap(await invoke(name, foreign), { foreign: packet(new Uint8Array([0, 128, 255])) });
    for (const payload of [null, undefined, new Uint16Array(1), new ArrayBuffer(1), [], new Proxy(new Uint8Array(1), {})]) {
      await failure(name, [{ first: row, late: packet(payload) }], TypeError, 'parameter values["late"]["payload"]');
    }
    const detached = new Uint8Array([1]);
    structuredClone(detached.buffer, { transfer: [detached.buffer] });
    await failure(name, [{ late: packet(detached) }], TypeError, 'parameter values["late"]["payload"]');
    const resizable = new ArrayBuffer(8, { maxByteLength: 16 });
    const outOfBounds = new Uint8Array(resizable, 2, 3); resizable.resize(1);
    await failure(name, [{ late: packet(outOfBounds) }], TypeError, 'parameter values["late"]["payload"]');
  }
  const bytes = new Uint8Array([1, 2]);
  const byteFields = { first: bytes, maybe: bytes, second: bytes };
  const byteOutput = invoke('echoByteFields', { first: byteFields, again: byteFields });
  equalMap(byteOutput, { first: byteFields, again: byteFields });
  const fields = Object.values(byteOutput).flatMap(row => [row.first, row.maybe, row.second]);
  assert.equal(new Set(fields.map(value => value.buffer)).size, fields.length);
  fields[0][0] = 9;
  for (const field of fields.slice(1)) assert.equal(field[0], 1);
  assert.equal(bytes[0], 1);
  equalMap(invoke('echoByteFields', { nullable: { first: bytes, maybe: null, second: bytes } }), { nullable: { first: bytes, maybe: null, second: bytes } });
  for (const name of ['echoNullablePackets', 'echoNullablePacketsAsync']) {
    assert.equal(await invoke(name, null), null);
    equalMap(await invoke(name, { null: null, packet: packet(bytes) }), { null: null, packet: packet(bytes) });
    await failure(name, [{ late: packet(undefined) }], TypeError, 'parameter values["late"]["payload"]');
  }
  equalMap(invoke('echoInlinePackets', { null: null, nullable: { name: 'nullable', payload: null }, packet: packet(bytes) }), { null: null, nullable: { name: 'nullable', payload: null }, packet: packet(bytes) });
  assert.equal(invoke('echoInlinePackets', null), null);

  for (const name of ['normalizePackets', 'normalizePacketsAsync']) {
    const payload = new Uint8Array([0, 128, 255]);
    const input = { packet: packet(payload) };
    const pending = invoke(name, input);
    assert.deepEqual(payload, new Uint8Array([0, 128, 255]));
    payload.fill(9); input.packet.payload = new Uint8Array([8]); delete input.packet;
    equalMap(await pending, { packet: packet(new Uint8Array([255, 127, 0])) });
  }
  for (const name of ['trackedPackets', 'trackedPacketsAsync']) {
    for (const args of [
      [{ first: packet(bytes), late: packet(undefined) }, { second: packet(bytes) }],
      [{ first: packet(bytes) }, { second: packet(bytes), late: packet(undefined) }],
    ]) {
      const before = invoke('calls');
      await failure(name, args, TypeError, `parameter ${Object.hasOwn(args[0], 'late') ? 'first' : 'second'}["late"]["payload"]`);
      assert.equal(invoke('calls'), before, 'all keys and arguments validate before business entry');
    }
    const firstBytes = new Uint8Array([1, 2]); const secondBytes = new Uint8Array([3, 4]);
    const first = { saved: packet(firstBytes) }; const second = { returned: packet(secondBytes) };
    const pending = invoke(name, first, second);
    firstBytes.fill(7); first.saved.name = 'changed'; delete first.saved;
    structuredClone(secondBytes.buffer, { transfer: [secondBytes.buffer] }); delete second.returned;
    equalMap(await pending, { returned: packet(new Uint8Array([3, 4])) });
    const retained = invoke('readPackets');
    equalMap(retained, { saved: packet(new Uint8Array([1, 2])) });
    const mutable = invoke('readPackets'); mutable.saved.payload[0] = 9; delete mutable.saved;
    equalMap(invoke('readPackets'), { saved: packet(new Uint8Array([1, 2])) });
    invoke('changePackets');
    equalMap(retained, { saved: packet(new Uint8Array([1, 2])) });
    const changed = invoke('readPackets');
    equalMap(changed, { saved: packet(new Uint8Array([254, 2])), repeat: packet(new Uint8Array([254, 2])) });
    assert.notEqual(changed.saved, changed.repeat);
    assert.notEqual(changed.saved.payload.buffer, changed.repeat.payload.buffer);
  }
  const mutableUsers = { alice: user(), bob: user() };
  const usersPending = invoke('echoUsersAsync', mutableUsers);
  mutableUsers.alice.name = 'changed'; delete mutableUsers.bob;
  equalMap(await usersPending, { alice: user(), bob: user() });

  for (const name of ['badUsers', 'badUsersAsync']) {
    for (let mode = 0; mode <= 6; mode++) {
      const error = await failure(name, [mode], mode >= 5 ? TypeError : RangeError, 'result:');
      assert(!error.message.includes('result["first"]'), 'an unavailable next key must not reuse the previous key');
      assert(!error.message.includes('result["bad"]'), 'iterator/current/cast failures precede the next trustworthy entry');
      equalMap(await invoke('echoUsers', { recovered: user() }), { recovered: user() });
    }
    const error = await failure(name, [7], RangeError, 'result["bad"]["age"]');
    assert.equal(error.message, 'RangeError: result["bad"]["age"]: Integer must be within the JavaScript safe integer range');
  }

  // Retained output survives later calls and collection without aliasing.
  assert.equal(typeof global.gc, 'function', 'run with --expose-gc');
  const retained = invoke('echoPackets', { saved: packet(new Uint8Array([1, 2, 3])) });
  const concurrent = [];
  for (let index = 0; index < 16; index++) {
    const input = { [String(index)]: packet(new Uint8Array([index])) };
    const pending = invoke('echoPacketsAsync', input);
    input[String(index)].payload[0] = 99; delete input[String(index)];
    concurrent.push(pending.then(output => equalMap(output, { [String(index)]: packet(new Uint8Array([index])) })));
  }
  await Promise.all(concurrent);
  global.gc(); await immediate(); global.gc();
  equalMap(retained, { saved: packet(new Uint8Array([1, 2, 3])) });
  await immediate(); await immediate();
  assert.deepEqual(unhandled, []);
  console.log(JSON.stringify({ checks, nativeFunctions: names.length, node: process.version, retained: true }));
} finally {
  process.removeListener('unhandledRejection', onUnhandled);
  process.removeListener('uncaughtException', onUnhandled);
}
