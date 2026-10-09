import assert from 'node:assert/strict';
import { setImmediate as immediate } from 'node:timers/promises';
import { runInNewContext } from 'node:vm';
import * as api from '@napi/records';
import * as subpath from '@napi/records/module.wasm';
import * as relative from './dist/module.wasm';

const names = [
  'echoUser', 'normalizeUser', 'echoUserAsync', 'echoAlias', 'echoAliasAsync',
  'echoNullableAlias', 'echoNullableAliasAsync', 'echoChain', 'echoChainAsync',
  'echoReexport', 'echoInline', 'echoInlineAsync', 'echoMixed', 'echoMixedAsync',
  'echoSpecial', 'echoSpecialAsync', 'echoPart', 'echoPartAsync', 'calls',
  'tracked', 'trackedAsync', 'readStored', 'readStoredAsync', 'changeStored',
  'unsafeUser', 'unsafeUserAsync', 'unsafeMixed', 'unsafeMixedAsync',
  'inlineOne', 'inlineOneAsync', 'User', 'echoPartNullable', 'echoPartNullableAsync',
  'echoPacket', 'echoPacketAsync', 'normalizePacket', 'normalizePacketAsync', 'echoPacketAlias', 'echoMaybePacket', 'echoMaybePacketAsync', 'echoByteFields', 'echoByteFieldsAsync', 'repeatByteFields', 'repeatByteFieldsAsync', 'echoInlineBytes', 'echoInlineBytesAsync', 'trackedPacket', 'trackedPacketAsync', 'readPacket', 'readPacketAsync', 'changePacket', 'echoPartPacket', 'echoPartPacketAsync',
];
for (const name of names) {
  assert.equal(typeof api[name], 'function', name);
  assert.equal(api[name], subpath[name], `${name} package subpath`);
  assert.equal(api[name], relative[name], `${name} relative raw Wasm`);
  assert.match(Function.prototype.toString.call(api[name]), /\[native code\]/, name);
}
for (const name of ['UserAlias', 'NullableUser', 'MaybeUserAlias', 'ReexportUser', 'Mixed', 'SpecialFields', 'PartValue', 'Packet', 'PacketAlias', 'MaybePacket', 'ReexportPacket', 'ByteFields', 'PartPacket']) {
  assert.equal(Object.hasOwn(api, name), false, `${name} is only a type export`);
}

let checks = 0;
function invoke(name, ...args) {
  checks++;
  if (!name.endsWith('Async')) return api[name](...args);
  let promise;
  assert.doesNotThrow(() => { promise = api[name](...args); }, `${name} returns instead of throwing`);
  assert(promise instanceof Promise, `${name} returns a genuine Promise`);
  return bounded(promise);
}
async function bounded(promise) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error('Record Promise did not settle')), 3000);
    })]);
  } finally {
    clearTimeout(timer);
  }
}
async function failure(name, args, type, context = []) {
  let caught = false;
  let caughtError;
  try {
    await invoke(name, ...args);
  } catch (error) {
    caught = true;
    caughtError = error;
    assert(error instanceof type, `${name}: ${error?.constructor?.name}: ${error?.message}`);
    for (const part of context) assert.equal(error.message.split(part).length - 1, 1, `${name}: ${error.message} must contain ${part} exactly once`);
  }
  assert(caught, `${name} must fail`);
  return caughtError;
}
async function identicalFailure(name, input, reason) {
  let caught = false;
  try {
    await invoke(name, input);
  } catch (error) {
    caught = true;
    assert.equal(error, reason, `${name} preserves the original thrown value`);
  }
  assert(caught, `${name} must fail`);
}
function equalRecord(actual, expected) {
  assert.equal(Object.getPrototypeOf(actual), null, 'record output has null prototype');
  assert.deepEqual(Reflect.ownKeys(actual).sort(), Object.keys(expected).sort(), 'only declared fields are returned');
  for (const key of Object.keys(expected)) {
    const descriptor = Object.getOwnPropertyDescriptor(actual, key);
    assert(Object.hasOwn(descriptor, 'value'), `${key} is an own data property`);
    assert.equal(descriptor.enumerable, true);
    assert.equal(descriptor.writable, true);
    assert.equal(descriptor.configurable, true);
    assert(Object.is(descriptor.value, expected[key]), `${key} preserves the scalar value`);
  }
}

function equalByteRecord(actual, expected) {
  assert.equal(Object.getPrototypeOf(actual), null);
  assert.deepEqual(Reflect.ownKeys(actual).sort(), Object.keys(expected).sort());
  for (const key of Object.keys(expected)) {
    const descriptor = Object.getOwnPropertyDescriptor(actual, key);
    assert(Object.hasOwn(descriptor, 'value'));
    assert.equal(descriptor.enumerable, true);
    assert.equal(descriptor.writable, true);
    assert.equal(descriptor.configurable, true);
    if (expected[key] instanceof Uint8Array) {
      assert(actual[key] instanceof Uint8Array);
      assert(actual[key].buffer instanceof ArrayBuffer);
      assert.deepEqual(actual[key], expected[key]);
    } else assert(Object.is(actual[key], expected[key]));
  }
}

const user = () => ({ name: 'Dart', age: 20, active: null });
const mixed = () => ({
  flag: true, count: 42, value: -0, text: '你好🚀\ud800x\udfff\0',
  maybeFlag: null, maybeCount: null, maybeValue: null, maybeText: null,
});
const userCalls = [
  'echoUser', 'echoUserAsync', 'echoAlias', 'echoAliasAsync',
  'echoNullableAlias', 'echoNullableAliasAsync', 'echoChain', 'echoChainAsync',
  'echoReexport', 'User',
];
const nullableCalls = new Set(['echoUserAsync', 'echoNullableAlias', 'echoNullableAliasAsync', 'echoChain', 'echoChainAsync']);
const unhandled = [];
const onUnhandled = error => unhandled.push(error);
process.on('unhandledRejection', onUnhandled);
process.on('uncaughtException', onUnhandled);
try {
  for (const name of userCalls) {
    const input = user();
    const result = await invoke(name, input);
    equalRecord(result, input);
    assert.notEqual(result, input);
    result.name = 'output changed';
    equalRecord(await invoke(name, input), input);
    equalRecord(await invoke(name, { age: 20, active: null, name: 'Dart' }), input);
    equalRecord(await invoke(name, Object.freeze(input)), input);
    equalRecord(await invoke(name, Object.assign(Object.create(null), input)), input);
    equalRecord(await invoke(name, input, { ignored: true }), input);
    if (nullableCalls.has(name)) assert.equal(await invoke(name, null), null);
    else await failure(name, [null], TypeError, ['parameter']);
    await failure(name, [undefined], TypeError, ['parameter']);
    await failure(name, [], TypeError, ['parameter']);
    for (const key of ['name', 'age', 'active']) {
      const missing = user();
      delete missing[key];
      await failure(name, [missing], TypeError, ['parameter', `["${key}"]`]);
      await failure(name, [{ ...input, [key]: undefined }], TypeError, ['parameter', `["${key}"]`]);
    }
    for (const value of [Number.MIN_SAFE_INTEGER, Number.MAX_SAFE_INTEGER, 0, -1]) {
      equalRecord(await invoke(name, { ...input, age: value }), { ...input, age: value });
    }
    for (const value of [Number.MIN_SAFE_INTEGER - 1, Number.MAX_SAFE_INTEGER + 1]) {
      await failure(name, [{ ...input, age: value }], RangeError, ['parameter', '["age"]']);
    }
  }
  equalRecord(await invoke('normalizeUser', { name: '  Dart  ', age: -4, active: null }), { name: 'Dart', age: 0, active: false });

  // Each leaf is independently strict/nullable, without coercion or JSON loss.
  const valid = {
    flag: [false, true], count: [Number.MIN_SAFE_INTEGER, Number.MAX_SAFE_INTEGER, 0],
    value: [NaN, Infinity, -Infinity, -0, 0.125], text: ['', '你好🚀', '\ud800', '\udfff', 'a\0b'],
    maybeFlag: [false, true, null], maybeCount: [Number.MIN_SAFE_INTEGER, Number.MAX_SAFE_INTEGER, null],
    maybeValue: [NaN, Infinity, -Infinity, -0, null], maybeText: ['', '\ud800x\udfff', null],
  };
  const invalid = {
    flag: [1, '', {}, new Boolean(true), null], count: [1.5, NaN, Infinity, 1n, '1', null],
    value: [true, 1n, new Number(1), null], text: [1, new String('boxed'), Symbol('text'), null],
    maybeFlag: [1, '', {}], maybeCount: [1.5, NaN, Infinity, 1n],
    maybeValue: [true, 1n, new Number(1)], maybeText: [1, new String('boxed'), {}],
  };
  for (const name of ['echoMixed', 'echoMixedAsync']) {
    for (const [key, values] of Object.entries(valid)) {
      for (const value of values) {
        const input = { ...mixed(), [key]: value };
        equalRecord(await invoke(name, input), input);
      }
    }
    for (const [key, values] of Object.entries(invalid)) {
      for (const value of [...values, undefined]) {
        const error = await failure(name, [{ ...mixed(), [key]: value }], TypeError, ['parameter value', `["${key}"]`]);
        if (key === 'count' && value === 1.5) assert.equal(error.message, 'parameter value["count"]: Expected an integer');
      }
      const missing = mixed();
      delete missing[key];
      await failure(name, [missing], TypeError, ['parameter value', `["${key}"]`]);
    }
    for (const key of ['count', 'maybeCount']) {
      for (const value of [Number.MIN_SAFE_INTEGER - 1, Number.MAX_SAFE_INTEGER + 1]) {
        const error = await failure(name, [{ ...mixed(), [key]: value }], RangeError, ['parameter value', `["${key}"]`]);
        assert.equal(error.message, `RangeError: parameter value["${key}"]: Integer must be within the JavaScript safe integer range`);
      }
    }
  }

  const inline = { label: '\ud800\0', count: -42, flag: null, score: NaN };
  for (const name of ['echoInline', 'echoInlineAsync']) equalRecord(await invoke(name, inline), inline);
  assert.equal(await invoke('echoInlineAsync', null), null);
  for (const name of ['inlineOne', 'inlineOneAsync']) equalRecord(await invoke(name, { value: 42 }), { value: 42 });
  const part = { code: 7, message: 'part typedef' };
  for (const name of ['echoPart', 'echoPartAsync', 'echoPartNullable', 'echoPartNullableAsync']) equalRecord(await invoke(name, part), part);
  assert.equal(await invoke('echoPartNullable', null), null);
  assert.equal(await invoke('echoPartNullableAsync', null), null);
  const special = { constructor: 'own', prototype: '\ud800', then: 'not callable', $value: -0 };
  for (const name of ['echoSpecial', 'echoSpecialAsync']) {
    equalRecord(await invoke(name, special), special);
    const error = await failure(name, [{ ...special, $value: 'bad' }], TypeError, ['parameter value["$value"]']);
    assert.equal(error.message, 'parameter value["$value"]: Expected a number');
  }

  // A record reads its fixed own fields, independent of enumerability.
  let getterCalls = 0;
  for (const name of ['echoUser', 'echoUserAsync']) {
    const hidden = Object.create(null);
    for (const [key, value] of Object.entries(user())) Object.defineProperty(hidden, key, { value });
    equalRecord(await invoke(name, hidden), user());
    for (const key of ['name', 'age', 'active']) {
      const accessor = user();
      Object.defineProperty(accessor, key, { get() { getterCalls++; return user()[key]; } });
      await failure(name, [accessor], TypeError, ['parameter user', `["${key}"]`]);
      const setter = user();
      Object.defineProperty(setter, key, { set() { getterCalls++; } });
      await failure(name, [setter], TypeError, ['parameter user', `["${key}"]`]);
    }
    const inherited = user();
    delete inherited.active;
    Object.defineProperty(Object.prototype, 'active', { configurable: true, get() { getterCalls++; return null; } });
    try {
      await failure(name, [inherited], TypeError, ['parameter user', '["active"]']);
    } finally {
      delete Object.prototype.active;
    }
    const extra = user();
    Object.defineProperty(extra, 'ignored', { enumerable: true, get() { getterCalls++; throw Error('extra getter'); } });
    Object.defineProperty(extra, '__proto__', { enumerable: true, value: extra });
    extra[Symbol('ignored')] = extra;
    equalRecord(await invoke(name, extra), user());
    const reflected = [];
    const proxy = new Proxy(extra, {
      ownKeys() { throw Error('must not enumerate extras'); },
      get() { throw Error('must not read getters'); },
      getOwnPropertyDescriptor(target, key) {
        assert(['active', 'age', 'name'].includes(key), `must not inspect unknown ${String(key)}`);
        reflected.push(key);
        return Reflect.getOwnPropertyDescriptor(target, key);
      },
    });
    equalRecord(await invoke(name, proxy), user());
    assert.deepEqual(reflected.sort(), ['active', 'age', 'name']);
    for (const input of [[], new Date(), new Map(), new Set(), new Uint8Array(), new (class UserData { name = 'Dart'; age = 20; active = null; })(), Object.assign(Object.create({}), user()), 'text', 42, true]) {
      await failure(name, [input], TypeError, ['parameter user']);
    }
    for (const key of ['name', 'age', 'active']) {
      for (const value of [[], {}, Promise.resolve(1)]) {
        await failure(name, [{ ...user(), [key]: value }], TypeError, ['parameter user', `["${key}"]`]);
      }
    }
  }
  assert.equal(getterCalls, 0, 'neither required nor unknown getters execute');

  // An ordinary Object prototype remains valid when its constructor is absent.
  const objectConstructor = Object.getOwnPropertyDescriptor(Object.prototype, 'constructor');
  delete Object.prototype.constructor;
  try {
    equalRecord(await invoke('echoUser', user()), user());
    equalRecord(await invoke('echoUserAsync', user()), user());
  } finally {
    Object.defineProperty(Object.prototype, 'constructor', objectConstructor);
  }
  const foreign = runInNewContext("({name:'你好\\ud800',age:Number.MAX_SAFE_INTEGER,active:false})");
  for (const name of ['echoUser', 'echoUserAsync']) equalRecord(await invoke(name, foreign), { name: foreign.name, age: foreign.age, active: foreign.active });
  const foreignMixed = runInNewContext("({flag:true,count:Number.MIN_SAFE_INTEGER,value:NaN,text:'\\udfff',maybeFlag:null,maybeCount:null,maybeValue:-0,maybeText:null})");
  for (const name of ['echoMixed', 'echoMixedAsync']) equalRecord(await invoke(name, foreignMixed), { ...foreignMixed });

  // All fields of all arguments are checked before the business counter moves.
  for (const name of ['tracked', 'trackedAsync']) {
    for (const args of [[{ ...user(), age: 'bad' }, user()], [user(), { ...user(), name: 42 }], [user(), { ...user(), active: undefined }]]) {
      const before = invoke('calls');
      await failure(name, args, TypeError, ['parameter']);
      assert.equal(invoke('calls'), before);
    }
    const first = user();
    const second = { name: 'second', age: 21, active: true };
    const pending = invoke(name, first, second);
    first.name = 'changed after call'; first.age = 0;
    second.name = 'changed after call'; second.active = false;
    equalRecord(await pending, { name: 'second', age: 21, active: true });
    const saved = await invoke('readStored');
    equalRecord(saved, user());
    saved.name = 'changed output';
    equalRecord(await invoke('readStoredAsync'), user());
    const previous = await invoke('readStored');
    assert.equal(invoke('changeStored'), undefined);
    equalRecord(previous, user());
    equalRecord(await invoke('readStored'), { name: 'changed', age: 2, active: true });
  }
  for (const name of ['unsafeUser', 'unsafeUserAsync']) {
    const error = await failure(name, [], RangeError, ['result["age"]']);
    assert.equal(error.message, 'RangeError: result["age"]: Integer must be within the JavaScript safe integer range');
  }
  for (const name of ['unsafeMixed', 'unsafeMixedAsync']) {
    const error = await failure(name, [], RangeError, ['result["count"]']);
    assert.equal(error.message, 'RangeError: result["count"]: Integer must be within the JavaScript safe integer range');
  }

  // Proxy exceptions preserve identity, including diagnostic accessors that throw.
  const reasons = [new Error('reflection'), new TypeError('reflection type'), 'reason', 42, Symbol('reason')];
  const hostile = new Error('original error');
  Object.defineProperty(hostile, 'stack', { get() { throw Error('stack getter'); } });
  Object.defineProperty(hostile, 'message', { get() { throw Error('message getter'); } });
  reasons.push(hostile);
  for (const name of ['echoUser', 'echoUserAsync']) {
    for (const reason of reasons) {
      await identicalFailure(name, new Proxy(user(), { getOwnPropertyDescriptor() { throw reason; } }), reason);
      await identicalFailure(name, new Proxy(user(), { getPrototypeOf() { throw reason; } }), reason);
    }
    for (const reason of [null, undefined]) {
      await failure(name, [new Proxy(user(), { getOwnPropertyDescriptor() { throw reason; } })], Error);
    }
    equalRecord(await invoke(name, user()), user());
  }

  const pending = [];
  for (let index = 0; index < 24; index++) {
    const input = { name: `concurrent ${index}`, age: index, active: index % 2 === 0 };
    const expected = { ...input };
    pending.push(invoke('echoUserAsync', input).then(output => equalRecord(output, expected)));
    input.name = 'mutated'; input.age = -1;
  }
  await Promise.all(pending);

  // Byte fields retain ordinary record descriptors while owning their storage.
  const packet = payload => ({ name: 'packet', payload });
  const packetNames = ['echoPacket', 'echoPacketAsync', 'echoPacketAlias', 'echoMaybePacket', 'echoMaybePacketAsync'];
  for (const name of packetNames) {
    const input = Object.freeze(packet(new Uint8Array([0, 128, 255])));
    const output = await invoke(name, input);
    equalByteRecord(output, packet(new Uint8Array([0, 128, 255])));
    assert.notEqual(output, input);
    assert.notEqual(output.payload.buffer, input.payload.buffer);
    output.name = 'changed result'; output.payload[0] = 7;
    assert.equal(input.payload[0], 0);
    equalByteRecord(await invoke(name, input), packet(new Uint8Array([0, 128, 255])));
    const empty = packet(new Uint8Array());
    const emptyOutput = await invoke(name, empty);
    equalByteRecord(emptyOutput, empty);
    assert.notEqual(emptyOutput.payload.buffer, empty.payload.buffer);
    if (name.startsWith('echoMaybe')) assert.equal(await invoke(name, null), null);
    else await failure(name, [null], TypeError, ['parameter value']);
  }
  for (const name of ['echoPacket', 'echoPacketAsync']) {
    for (const bytes of [new Uint8Array([99, 0, 128, 255, 88]).subarray(1, 4), Buffer.from([99, 0, 128, 255, 88]).subarray(1, 4)]) {
      const output = await invoke(name, packet(bytes));
      equalByteRecord(output, packet(new Uint8Array([0, 128, 255])));
      assert.notEqual(output.payload.buffer, bytes.buffer);
      assert.equal(output.payload.byteOffset, 0);
      assert.equal(output.payload.byteLength, 3);
    }
    const foreignPacket = runInNewContext("({name:'foreign',payload:new Uint8Array([0,128,255])})");
    equalByteRecord(await invoke(name, foreignPacket), { name: 'foreign', payload: new Uint8Array([0, 128, 255]) });
    const sharedBytes = new Uint8Array(new SharedArrayBuffer(3));
    sharedBytes.set([0, 128, 255]);
    const sharedPending = invoke(name, packet(sharedBytes));
    sharedBytes.fill(7);
    const sharedOutput = await sharedPending;
    equalByteRecord(sharedOutput, packet(new Uint8Array([0, 128, 255])));
    assert(sharedOutput.payload.buffer instanceof ArrayBuffer);
    const resizableBuffer = new ArrayBuffer(8, { maxByteLength: 16 });
    const resizableBytes = new Uint8Array(resizableBuffer, 2, 3);
    resizableBytes.set([0, 128, 255]);
    const resizablePending = invoke(name, packet(resizableBytes));
    resizableBuffer.resize(1);
    equalByteRecord(await resizablePending, packet(new Uint8Array([0, 128, 255])));
    const outOfBounds = new Uint8Array(new ArrayBuffer(8, { maxByteLength: 16 }), 2, 3);
    outOfBounds.buffer.resize(1);
    await failure(name, [packet(outOfBounds)], TypeError, ['parameter value["payload"]']);
    const detached = new Uint8Array([1, 2]);
    structuredClone(detached.buffer, { transfer: [detached.buffer] });
    const detachedError = await failure(name, [packet(detached)], TypeError, ['parameter value["payload"]']);
    assert(detachedError.message.length > 'parameter value["payload"]'.length);
    for (const payload of [undefined, null, [], new ArrayBuffer(3), new DataView(new ArrayBuffer(3)), new Uint8ClampedArray(3), new Int8Array(3), new Uint16Array(3), { [Symbol.toStringTag]: 'Uint8Array' }, new Proxy(new Uint8Array(3), {})]) {
      await failure(name, [packet(payload)], TypeError, ['parameter value["payload"]']);
    }
    await failure(name, [{ name: 'missing' }], TypeError, ['parameter value["payload"]']);
    const hidden = Object.create(null);
    Object.defineProperties(hidden, { name: { value: 'hidden' }, payload: { value: new Uint8Array([3]) } });
    equalByteRecord(await invoke(name, hidden), { name: 'hidden', payload: new Uint8Array([3]) });
    let byteGetters = 0;
    const accessor = packet(new Uint8Array([3]));
    Object.defineProperty(accessor, 'payload', { get() { byteGetters++; return new Uint8Array([3]); } });
    await failure(name, [accessor], TypeError, ['parameter value["payload"]']);
    const inherited = { name: 'inherited' };
    Object.defineProperty(Object.prototype, 'payload', { configurable: true, get() { byteGetters++; return new Uint8Array([3]); } });
    try {
      await failure(name, [inherited], TypeError, ['parameter value["payload"]']);
    } finally {
      delete Object.prototype.payload;
    }
    const view = new Uint8Array([3]);
    for (const key of ['length', 'buffer', 'byteOffset', 'byteLength', Symbol.iterator, Symbol.toStringTag]) {
      Object.defineProperty(view, key, { get() { byteGetters++; throw Error('unused byte getter'); } });
    }
    const extra = packet(view);
    Object.defineProperty(extra, 'ignored', { get() { byteGetters++; throw Error('unused record getter'); } });
    const proxy = new Proxy(extra, {
      get() { throw Error('must not read record getters'); },
      ownKeys() { throw Error('must not enumerate extra record fields'); },
      getOwnPropertyDescriptor(target, key) {
        assert(['name', 'payload'].includes(key));
        return Reflect.getOwnPropertyDescriptor(target, key);
      },
    });
    equalByteRecord(await invoke(name, proxy), packet(new Uint8Array([3])));
    assert.equal(byteGetters, 0);
    for (const reason of [new Error('byte reflection'), new TypeError('byte reflection type'), new RangeError('byte reflection range'), 'byte reason', Symbol('byte reason')]) {
      await identicalFailure(name, new Proxy(packet(new Uint8Array([3])), { getOwnPropertyDescriptor() { throw reason; } }), reason);
      await identicalFailure(name, new Proxy(packet(new Uint8Array([3])), { getPrototypeOf() { throw reason; } }), reason);
    }
    equalByteRecord(await invoke(name, packet(new Uint8Array([3]))), packet(new Uint8Array([3])));
  }
  for (const name of ['normalizePacket', 'normalizePacketAsync']) {
    const bytes = new Uint8Array([0, 128, 255]);
    const input = { name: ' sample ', payload: bytes };
    const pending = invoke(name, input);
    assert.deepEqual(bytes, new Uint8Array([0, 128, 255]), 'Dart business mutates only its owned payload');
    bytes.fill(7); input.name = 'changed'; input.payload = new Uint8Array([8]);
    const normalizedPacket = await pending;
    equalByteRecord(normalizedPacket, { name: 'sample', payload: new Uint8Array([255, 127, 0]) });
    assert.deepEqual(bytes, new Uint8Array([7, 7, 7]));
  }
  for (const name of ['echoInlineBytes', 'echoInlineBytesAsync']) {
    equalByteRecord(await invoke(name, { label: 'inline', payload: new Uint8Array([1]) }), { label: 'inline', payload: new Uint8Array([1]) });
    equalByteRecord(await invoke(name, { label: 'inline', payload: null }), { label: 'inline', payload: null });
    assert.equal(await invoke(name, null), null);
    await failure(name, [{ label: 'inline' }], TypeError, ['parameter value["payload"]']);
    await failure(name, [{ label: 'inline', payload: undefined }], TypeError, ['parameter value["payload"]']);
  }
  for (const name of ['echoPartPacket', 'echoPartPacketAsync']) {
    equalByteRecord(await invoke(name, { code: 4, payload: new Uint8Array([1]) }), { code: 4, payload: new Uint8Array([1]) });
    equalByteRecord(await invoke(name, { code: 4, payload: null }), { code: 4, payload: null });
  }
  assert.equal(await invoke('echoPartPacketAsync', null), null);
  for (const name of ['echoByteFields', 'echoByteFieldsAsync']) {
    const shared = new Uint8Array([1, 2]);
    const input = { first: shared, maybe: null, second: shared };
    const output = await invoke(name, input);
    equalByteRecord(output, { first: new Uint8Array([1, 2]), maybe: null, second: new Uint8Array([1, 2]) });
    assert.notEqual(output.first.buffer, output.second.buffer);
    assert.notEqual(output.first.buffer, shared.buffer);
    output.first[0] = 9;
    assert.equal(output.second[0], 1); assert.equal(shared[0], 1);
    for (const bad of [undefined, null, new Uint16Array(1)]) {
      const before = invoke('calls');
      await failure(name, [{ first: shared, maybe: null, second: bad }], TypeError, ['parameter value["second"]']);
      assert.equal(invoke('calls'), before, 'later byte field failure prevents business entry');
    }
    const detached = new Uint8Array([1]);
    structuredClone(detached.buffer, { transfer: [detached.buffer] });
    const before = invoke('calls');
    await failure(name, [{ first: shared, maybe: null, second: detached }], TypeError, ['parameter value["second"]']);
    assert.equal(invoke('calls'), before);
  }
  for (const name of ['repeatByteFields', 'repeatByteFieldsAsync']) {
    const input = packet(new Uint8Array([1, 2]));
    const output = await invoke(name, input);
    equalByteRecord(output, { first: new Uint8Array([1, 2]), maybe: new Uint8Array([1, 2]), second: new Uint8Array([1, 2]) });
    assert.notEqual(output.first.buffer, output.maybe.buffer);
    assert.notEqual(output.first.buffer, output.second.buffer);
    assert.notEqual(output.maybe.buffer, output.second.buffer);
    output.first[0] = 9;
    assert.equal(output.maybe[0], 1); assert.equal(output.second[0], 1); assert.equal(input.payload[0], 1);
  }
  for (const name of ['trackedPacket', 'trackedPacketAsync']) {
    const first = packet(new Uint8Array([1, 2]));
    for (const payload of [undefined, new Uint16Array(2)]) {
      const before = invoke('calls');
      await failure(name, [first, packet(payload)], TypeError, ['parameter second["payload"]']);
      assert.equal(invoke('calls'), before, 'later byte argument failure prevents business entry');
    }
    const firstBytes = first.payload;
    const secondBytes = new Uint8Array([3, 4]);
    const second = { name: 'second', payload: secondBytes };
    const pending = invoke(name, first, second);
    firstBytes.fill(7); first.name = 'changed'; first.payload = new Uint8Array([8]);
    structuredClone(secondBytes.buffer, { transfer: [secondBytes.buffer] });
    second.name = 'changed'; second.payload = new Uint8Array([8]);
    equalByteRecord(await pending, { name: 'second', payload: new Uint8Array([3, 4]) });
    const saved = invoke('readPacket');
    equalByteRecord(saved, packet(new Uint8Array([1, 2])));
    saved.payload[0] = 9;
    equalByteRecord(await invoke('readPacketAsync'), packet(new Uint8Array([1, 2])));
    const previous = invoke('readPacket');
    invoke('changePacket');
    equalByteRecord(previous, packet(new Uint8Array([1, 2])));
    equalByteRecord(invoke('readPacket'), { name: 'changed', payload: new Uint8Array([254, 2]) });
    assert.deepEqual(firstBytes, new Uint8Array([7, 7]));
    await failure(name, [{ name: 'fail', payload: new Uint8Array([1]) }, packet(new Uint8Array([2]))], TypeError, ['packet failure']);
    equalByteRecord(await invoke(name, packet(new Uint8Array([1])), packet(new Uint8Array([2]))), packet(new Uint8Array([2])));
  }

  // Repeated discarded strings/objects must not become retained boundary state.
  assert.equal(typeof global.gc, 'function', 'run with --expose-gc');
  const retainedOutputs = [];
  const retainedByteOutputs = [];
  const leakProbe = process.env.NAPI_RECORDS_RETAIN_OUTPUTS === '1';
  const codeUnits = new Uint16Array(8192);
  codeUnits.fill(0x4e2d);
  let batchId = 0;
  async function batch() {
    const id = batchId++;
    for (let index = 0; index < 2048; index++) {
      // Flat, unique two-byte strings avoid a shared rope fooling the leak probe.
      codeUnits[0] = id;
      codeUnits[1] = index;
      const input = { name: String.fromCharCode(...codeUnits), age: index, active: null };
      const output = invoke('echoUser', input);
      assert.equal(output.age, index);
      assert.equal(output.name, input.name);
      if (leakProbe) retainedOutputs.push(output);
      const byteOutput = invoke('echoPacket', { name: input.name, payload: new Uint8Array(8192) });
      assert.equal(byteOutput.payload.length, 8192);
      if (leakProbe) retainedByteOutputs.push(byteOutput);
    }
    for (let index = 0; index < 32; index += 8) {
      await Promise.all(Array.from({ length: 8 }, (_, offset) => invoke('echoUserAsync', { name: `batch ${id}`, age: index + offset, active: null })));
    }
  }
  async function memoryAfterGC() {
    global.gc(); await immediate();
    global.gc(); await immediate();
    return process.memoryUsage();
  }
  await batch();
  const before = await memoryAfterGC();
  await batch();
  const after = await memoryAfterGC();
  const retained = { heapUsed: after.heapUsed - before.heapUsed, arrayBuffers: after.arrayBuffers - before.arrayBuffers };
  const limit = 16 * 1024 * 1024;
  assert(retained.heapUsed < limit, `host heap retained ${retained.heapUsed}`);
  assert(retained.arrayBuffers < limit, `array buffers retained ${retained.arrayBuffers}`);
  assert.equal(retainedOutputs.length, leakProbe ? 4096 : 0);
  assert.equal(retainedByteOutputs.length, leakProbe ? 4096 : 0);
  await immediate(); await immediate();
  assert.deepEqual(unhandled, [], 'record errors must not escape Promise settlement');
  console.log(JSON.stringify({ checks, nativeFunctions: names.length, node: process.version, retained }));
} finally {
  process.removeListener('unhandledRejection', onUnhandled);
  process.removeListener('uncaughtException', onUnhandled);
}
