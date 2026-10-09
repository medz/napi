import assert from 'node:assert/strict';
import { setImmediate as immediate } from 'node:timers/promises';
import { runInNewContext } from 'node:vm';
import * as api from '@napi/batch';
import * as subpath from '@napi/batch/module.wasm';
import * as relative from './dist/module.wasm';

const names = [
  'normalizeUsers', 'normalizeUsersAsync', 'totalAge', 'totalAgeAsync',
  'echoUsers', 'echoUsersAsync', 'echoNullableUsers', 'echoNullableUsersAsync',
  'echoNullableContainerUsers', 'echoNullableContainerUsersAsync',
  'echoNullableBothUsers', 'echoNullableBothUsersAsync', 'echoMixed', 'echoMixedAsync',
  'echoNullableAlias', 'echoNullableAliasAsync', 'echoChain', 'echoChainAsync',
  'echoInline', 'echoInlineAsync', 'echoSpecial', 'echoSpecialAsync', 'calls',
  'tracked', 'trackedAsync', 'readStored', 'readStoredAsync', 'changeStored',
  'repeatFirst', 'repeatFirstAsync', 'unsafeUsers', 'unsafeUsersAsync',
  'unsafeMixed', 'unsafeMixedAsync', 'echoPart', 'echoPartAsync',
  'invalidLengthUsers', 'invalidLengthUsersAsync', 'invalidIndexReads', 'echoReadonlyArrays',
  'echoPackets', 'echoPacketsAsync', 'normalizePackets', 'normalizePacketsAsync', 'echoNullablePackets', 'echoNullablePacketsAsync', 'echoInlinePackets', 'echoInlinePacketsAsync', 'echoByteFieldsList', 'echoByteFieldsListAsync', 'repeatFirstPacket', 'repeatFirstPacketAsync', 'trackedPackets', 'trackedPacketsAsync', 'readPackets', 'readPacketsAsync', 'changePackets', 'echoPartPackets', 'echoPartPacketsAsync',
];
for (const name of names) {
  assert.equal(typeof api[name], 'function', name);
  assert.equal(api[name], subpath[name], `${name} package subpath`);
  assert.equal(api[name], relative[name], `${name} relative raw Wasm`);
  assert.match(Function.prototype.toString.call(api[name]), /\[native code\]/, name);
}
for (const name of ['User', 'UserAlias', 'MaybeUserAlias', 'Mixed', 'SpecialFields', 'BatchPart', 'ReadonlyArray', 'Packet', 'MaybePacket', 'ByteFields', 'BatchPacket']) {
  assert.equal(Object.hasOwn(api, name), false, `${name} is only a nested type export`);
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
      timer = setTimeout(() => reject(new Error('Record-list Promise did not settle')), 3000);
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
  assert.deepEqual(Reflect.ownKeys(actual).sort(), Object.keys(expected).sort());
  for (const key of Object.keys(expected)) {
    const descriptor = Object.getOwnPropertyDescriptor(actual, key);
    assert(Object.hasOwn(descriptor, 'value'), `${key} is an own data property`);
    assert.equal(descriptor.enumerable, true);
    assert.equal(descriptor.writable, true);
    assert.equal(descriptor.configurable, true);
    assert(Object.is(descriptor.value, expected[key]), `${key} preserves the scalar value`);
  }
}
function equalBatch(actual, expected) {
  assert(Array.isArray(actual));
  assert.equal(actual.length, expected.length);
  for (let index = 0; index < expected.length; index++) {
    const descriptor = Object.getOwnPropertyDescriptor(actual, index);
    assert(Object.hasOwn(descriptor, 'value'));
    if (expected[index] === null) assert.equal(descriptor.value, null);
    else equalRecord(descriptor.value, expected[index]);
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
    } else assert(Object.is(descriptor.value, expected[key]));
  }
}
function equalByteBatch(actual, expected) {
  assert(Array.isArray(actual));
  assert.equal(actual.length, expected.length);
  for (let index = 0; index < expected.length; index++) {
    assert(Object.hasOwn(Object.getOwnPropertyDescriptor(actual, index), 'value'));
    if (expected[index] === null) assert.equal(actual[index], null);
    else equalByteRecord(actual[index], expected[index]);
  }
}
const user = () => ({ name: 'Dart', age: 20, active: null });
const mixed = () => ({
  flag: true, count: 42, value: -0, text: '你好🚀\ud800x\udfff\0',
  maybeFlag: null, maybeCount: null, maybeValue: null, maybeText: null,
});
const variants = [
  ['echoUsers', false, false], ['echoNullableUsers', false, true],
  ['echoNullableContainerUsers', true, false], ['echoNullableBothUsers', true, true],
  ['echoNullableAlias', false, true], ['echoChain', false, false],
];
const unhandled = [];
const onUnhandled = error => unhandled.push(error);
process.on('unhandledRejection', onUnhandled);
process.on('uncaughtException', onUnhandled);
try {
  // Container, element, and required nullable-field rules are independent.
  for (const [base, nullableContainer, nullableElement] of variants) {
    for (const suffix of ['', 'Async']) {
      const name = base + suffix;
      const input = [user(), ...(nullableElement ? [null] : [])];
      const output = await invoke(name, input);
      equalBatch(output, input);
      assert.notEqual(output, input);
      assert.notEqual(output[0], input[0]);
      output[0].name = 'changed output';
      equalBatch(await invoke(name, input), input);
      const empty = [];
      const emptyOutput = await invoke(name, empty);
      equalBatch(emptyOutput, []);
      assert.notEqual(emptyOutput, empty);
      Object.freeze(input[0]);
      const frozen = Object.freeze(input);
      const copied = await invoke(name, frozen);
      equalBatch(copied, frozen);
      assert.notEqual(copied, frozen);
      assert.notEqual(copied[0], frozen[0]);
      assert.equal(Object.isFrozen(copied), false);
      assert.equal(Object.isFrozen(copied[0]), false);
      copied[0].name = 'mutable frozen-input result';
      copied.push(user());
      assert.deepEqual(frozen, [user(), ...(nullableElement ? [null] : [])]);
      equalBatch(await invoke(name, input, [null]), input);
      if (nullableContainer) assert.equal(await invoke(name, null), null);
      else await failure(name, [null], TypeError, ['parameter values']);
      if (nullableElement) equalBatch(await invoke(name, [null, user()]), [null, user()]);
      else await failure(name, [[user(), null]], TypeError, ['parameter values[1]']);
      await failure(name, [undefined], TypeError, ['parameter values']);
      await failure(name, [], TypeError, ['parameter values']);
      await failure(name, [[user(), undefined]], TypeError, ['parameter values[1]']);
      for (const key of ['name', 'age', 'active']) {
        const missing = user();
        delete missing[key];
        await failure(name, [[user(), missing]], TypeError, [`parameter values[1]["${key}"]`]);
        await failure(name, [[user(), { ...user(), [key]: undefined }]], TypeError, [`parameter values[1]["${key}"]`]);
      }
    }
  }
  const readonlyArrays = Object.freeze([Object.freeze({ count: 1 }), Object.freeze({ count: 2 })]);
  const readonlyArrayOutput = invoke('echoReadonlyArrays', readonlyArrays);
  equalBatch(readonlyArrayOutput, readonlyArrays);
  assert.notEqual(readonlyArrayOutput, readonlyArrays);
  assert.notEqual(readonlyArrayOutput[0], readonlyArrays[0]);
  assert.notEqual(readonlyArrayOutput[1], readonlyArrays[1]);
  assert.equal(Object.isFrozen(readonlyArrayOutput), false);
  assert.equal(Object.isFrozen(readonlyArrayOutput[0]), false);
  readonlyArrayOutput[0].count = 3;
  readonlyArrayOutput.push({ count: 4 });
  assert.deepEqual(readonlyArrays, [{ count: 1 }, { count: 2 }]);
  const source = [{ name: ' Ada ', age: 42, active: null }, { name: ' Lin ', age: -2, active: true }];
  const normalized = [{ name: 'Ada', age: 42, active: false }, { name: 'Lin', age: 0, active: true }];
  equalBatch(await invoke('normalizeUsers', source), normalized);
  equalBatch(await invoke('normalizeUsersAsync', source), normalized);
  assert.equal(invoke('totalAge', source), 40);
  assert.equal(await invoke('totalAgeAsync', source), 40);
  assert.equal(invoke('totalAge', []), 0);
  for (const name of ['totalAge', 'totalAgeAsync']) {
    await failure(name, [[{ ...user(), age: Number.MAX_SAFE_INTEGER }, { ...user(), age: 1 }]], RangeError, ['safe integer']);
  }

  // Full scalar fidelity within mixed records at nonzero array positions.
  const valid = {
    flag: [false, true], count: [Number.MIN_SAFE_INTEGER, Number.MAX_SAFE_INTEGER, 0],
    value: [NaN, Infinity, -Infinity, -0, 0.125], text: ['', '你好🚀', '\ud800', '\udfff', 'a\0b'],
    maybeFlag: [false, true, null], maybeCount: [Number.MIN_SAFE_INTEGER, Number.MAX_SAFE_INTEGER, null],
    maybeValue: [NaN, Infinity, -Infinity, -0, null], maybeText: ['', '\ud800x\udfff', null],
  };
  const invalid = {
    flag: [1, new Boolean(true), null], count: [1.5, NaN, Infinity, 1n, null],
    value: [true, new Number(1), null], text: [1, new String('boxed'), null],
    maybeFlag: [1, {}], maybeCount: [1.5, Infinity, 1n],
    maybeValue: [false, new Number(1)], maybeText: [1, {}],
  };
  for (const name of ['echoMixed', 'echoMixedAsync']) {
    for (const [key, values] of Object.entries(valid)) {
      for (const value of values) {
        const input = [mixed(), { ...mixed(), [key]: value }];
        equalBatch(await invoke(name, input), input);
      }
    }
    for (const [key, values] of Object.entries(invalid)) {
      for (const value of [...values, undefined]) {
        const error = await failure(name, [[mixed(), { ...mixed(), [key]: value }]], TypeError, [`parameter values[1]["${key}"]`]);
        if (key === 'count' && value === 1.5) assert.equal(error.message, 'parameter values[1]["count"]: Expected an integer');
      }
    }
    for (const key of ['count', 'maybeCount']) {
      for (const value of [Number.MIN_SAFE_INTEGER - 1, Number.MAX_SAFE_INTEGER + 1]) {
        const error = await failure(name, [[mixed(), { ...mixed(), [key]: value }]], RangeError, [`parameter values[1]["${key}"]`]);
        assert.equal(error.message, `RangeError: parameter values[1]["${key}"]: Integer must be within the JavaScript safe integer range`);
      }
    }
  }
  const inline = [{ label: '\ud800\0', count: -42, flag: null, score: NaN }, null];
  for (const name of ['echoInline', 'echoInlineAsync']) {
    equalBatch(await invoke(name, inline), inline);
    assert.equal(await invoke(name, null), null);
  }
  const part = [{ code: 7, message: 'part typedef' }, null];
  for (const name of ['echoPart', 'echoPartAsync']) {
    equalBatch(await invoke(name, part), part);
    assert.equal(await invoke(name, null), null);
  }
  const special = [{ constructor: 'own', prototype: '\ud800', then: 'scalar', $value: -0 }];
  for (const name of ['echoSpecial', 'echoSpecialAsync']) {
    equalBatch(await invoke(name, special), special);
    const error = await failure(name, [[special[0], { ...special[0], $value: 'bad' }]], TypeError, ['parameter values[1]["$value"]']);
    assert.equal(error.message, 'parameter values[1]["$value"]: Expected a number');
  }

  // Dense own Array slots and fixed record fields; no getters or extra reflection.
  let getterCalls = 0;
  for (const name of ['echoUsers', 'echoUsersAsync']) {
    const hidden = Object.create(null);
    for (const [key, value] of Object.entries(user())) Object.defineProperty(hidden, key, { value });
    const hiddenIndex = [hidden];
    Object.defineProperty(hiddenIndex, '0', { enumerable: false });
    equalBatch(await invoke(name, hiddenIndex), [user()]);
    equalBatch(await invoke(name, [Object.freeze(user()), Object.assign(Object.create(null), user())]), [user(), user()]);
    const accessorIndex = [user(), user()];
    Object.defineProperty(accessorIndex, '1', { get() { getterCalls++; return user(); } });
    const inheritedIndex = [user(), , user()];
    const arrayPrototype = Object.create(Array.prototype);
    Object.defineProperty(arrayPrototype, '1', { get() { getterCalls++; return user(); } });
    Object.setPrototypeOf(inheritedIndex, arrayPrototype);
    for (const input of [[user(), , user()], accessorIndex, inheritedIndex]) {
      await failure(name, [input], TypeError, ['parameter values[1]']);
    }
    for (const input of [new Uint8Array([1]), { 0: user(), length: 1 }, new Set([user()]), 'text']) {
      await failure(name, [input], TypeError, ['parameter values']);
    }
    for (const input of [[], new Date(), new Map(), new Set(), new (class UserData { name = 'Dart'; age = 20; active = null; })(), Object.assign(Object.create({}), user()), 42, true]) {
      await failure(name, [[user(), input]], TypeError, ['parameter values[1]']);
    }
    for (const key of ['name', 'age', 'active']) {
      const accessor = user();
      Object.defineProperty(accessor, key, { get() { getterCalls++; return user()[key]; } });
      await failure(name, [[user(), accessor]], TypeError, [`parameter values[1]["${key}"]`]);
    }
    const inherited = user();
    delete inherited.active;
    Object.defineProperty(Object.prototype, 'active', { configurable: true, get() { getterCalls++; return null; } });
    try {
      await failure(name, [[user(), inherited]], TypeError, ['parameter values[1]["active"]']);
    } finally {
      delete Object.prototype.active;
    }
    const extra = user();
    Object.defineProperty(extra, 'ignored', { enumerable: true, get() { getterCalls++; throw Error('record extra'); } });
    Object.defineProperty(extra, '__proto__', { enumerable: true, value: extra });
    Object.defineProperty(extra, 'then', { get() { getterCalls++; throw Error('unknown then'); } });
    extra[Symbol('ignored')] = extra;
    const fieldsRead = [];
    const recordProxy = new Proxy(extra, {
      ownKeys() { throw Error('must not enumerate record extras'); },
      get() { throw Error('must not read record getters'); },
      getOwnPropertyDescriptor(target, key) {
        assert(['active', 'age', 'name'].includes(key), `must not inspect unknown ${String(key)}`);
        fieldsRead.push(key);
        return Reflect.getOwnPropertyDescriptor(target, key);
      },
    });
    const array = [recordProxy];
    Object.defineProperty(array, 'ignored', { get() { getterCalls++; throw Error('array extra'); } });
    array[Symbol('ignored')] = array;
    const arrayProxy = new Proxy(array, {
      ownKeys() { throw Error('must not enumerate array extras'); },
      get() { throw Error('must not read array getters'); },
      getOwnPropertyDescriptor(target, key) {
        assert(['length', '0'].includes(key), `must not inspect extra array ${String(key)}`);
        return Reflect.getOwnPropertyDescriptor(target, key);
      },
    });
    equalBatch(await invoke(name, arrayProxy), [user()]);
    assert.deepEqual(fieldsRead.sort(), ['active', 'age', 'name']);
  }
  assert.equal(getterCalls, 0);
  const foreign = runInNewContext("[{name:'你好\\ud800',age:Number.MAX_SAFE_INTEGER,active:false},Object.assign(Object.create(null),{name:'\\udfff',age:2,active:null})]");
  const expectedForeign = Array.from(foreign, value => ({ ...value }));
  for (const name of ['echoUsers', 'echoUsersAsync']) equalBatch(await invoke(name, foreign), expectedForeign);

  // All list elements and later arguments validate before business code runs.
  for (const name of ['tracked', 'trackedAsync']) {
    for (const args of [
      [[user(), user(), { ...user(), age: 'bad' }], [user()]],
      [[user()], [user(), user(), { name: 'missing', age: 1 }]],
      [[user()], [user(), , user()]],
    ]) {
      const before = invoke('calls');
      await failure(name, args, TypeError, ['parameter']);
      assert.equal(invoke('calls'), before);
    }
    const first = [user(), { name: 'first second', age: 21, active: true }];
    const second = [{ name: 'second', age: 22, active: false }];
    const pending = invoke(name, first, second);
    first[0].name = 'changed field'; first[1] = user(); first.push(user());
    second[0].active = true; second.splice(0);
    equalBatch(await pending, [{ name: 'second', age: 22, active: false }]);
    const saved = await invoke('readStored');
    const expected = [user(), { name: 'first second', age: 21, active: true }];
    equalBatch(saved, expected);
    saved[0].name = 'changed output'; saved.push(user());
    equalBatch(await invoke('readStoredAsync'), expected);
    const previous = await invoke('readStored');
    assert.equal(invoke('changeStored'), undefined);
    equalBatch(previous, expected);
    equalBatch(await invoke('readStored'), [{ name: 'changed', age: 2, active: true }, expected[1], { name: 'appended', age: 3, active: null }]);
  }
  for (const name of ['echoUsersAsync', 'normalizeUsersAsync']) {
    const input = [{ name: ' Ada ', age: 20, active: null }, user()];
    const pending = invoke(name, input);
    input[0].name = 'changed'; input[1] = { name: 'replacement', age: 1, active: true };
    input.length = 0;
    equalBatch(await pending, name === 'echoUsersAsync'
      ? [{ name: ' Ada ', age: 20, active: null }, user()]
      : [{ name: 'Ada', age: 20, active: false }, { ...user(), active: false }]);
  }
  for (const name of ['echoUsers', 'echoUsersAsync', 'repeatFirst', 'repeatFirstAsync']) {
    const shared = user();
    const output = await invoke(name, [shared, shared]);
    equalBatch(output, [user(), user()]);
    assert.notEqual(output[0], shared);
    assert.notEqual(output[0], output[1], 'reused Dart records still produce independent JS objects');
    output[0].name = 'mutated';
    equalRecord(output[1], user());
  }
  for (const name of ['unsafeUsers', 'unsafeUsersAsync']) {
    const error = await failure(name, [], RangeError, ['result[2]["age"]']);
    assert.equal(error.message, 'RangeError: result[2]["age"]: Integer must be within the JavaScript safe integer range');
  }
  for (const name of ['unsafeMixed', 'unsafeMixedAsync']) {
    const error = await failure(name, [], RangeError, ['result[0]["count"]']);
    assert.equal(error.message, 'RangeError: result[0]["count"]: Integer must be within the JavaScript safe integer range');
  }
  for (const name of ['invalidLengthUsers', 'invalidLengthUsersAsync']) {
    for (const length of [-1, 0x100000000]) {
      const before = invoke('invalidIndexReads');
      await failure(name, [length], RangeError, ['result']);
      assert.equal(invoke('invalidIndexReads'), before, `${name} rejects length ${length} before reading an element`);
    }
  }

  const reasons = [new Error('reflection'), new TypeError('reflection type'), 'reason', 42, Symbol('reason')];
  const hostile = new Error('original error');
  Object.defineProperty(hostile, 'stack', { get() { throw Error('stack getter'); } });
  Object.defineProperty(hostile, 'message', { get() { throw Error('message getter'); } });
  reasons.push(hostile);
  for (const name of ['echoUsers', 'echoUsersAsync']) {
    for (const reason of reasons) {
      await identicalFailure(name, new Proxy([user()], { getOwnPropertyDescriptor() { throw reason; } }), reason);
      await identicalFailure(name, [user(), new Proxy(user(), { getOwnPropertyDescriptor() { throw reason; } })], reason);
      await identicalFailure(name, [user(), new Proxy(user(), { getPrototypeOf() { throw reason; } })], reason);
    }
    for (const reason of [null, undefined]) {
      await failure(name, [[new Proxy(user(), { getOwnPropertyDescriptor() { throw reason; } })]], Error);
    }
    equalBatch(await invoke(name, [user()]), [user()]);
  }
  const pending = [];
  for (let index = 0; index < 24; index++) {
    const input = [{ name: `concurrent ${index}`, age: index, active: null }, null];
    const expected = [{ ...input[0] }, null];
    pending.push(invoke('echoNullableBothUsersAsync', input).then(output => equalBatch(output, expected)));
    input[0].name = 'mutated'; input.length = 0;
  }
  await Promise.all(pending);

  // Packet rows compose byte copies with existing List and record snapshots.
  const bytePacket = payload => ({ name: 'packet', payload });
  for (const name of ['echoPackets', 'echoPacketsAsync', 'echoNullablePackets', 'echoNullablePacketsAsync']) {
    const bytes = new Uint8Array([0, 128, 255]);
    const input = Object.freeze([Object.freeze(bytePacket(bytes))]);
    const output = await invoke(name, input);
    equalByteBatch(output, [bytePacket(new Uint8Array([0, 128, 255]))]);
    assert.notEqual(output, input); assert.notEqual(output[0], input[0]);
    assert.notEqual(output[0].payload.buffer, bytes.buffer);
    output[0].payload[0] = 7; output[0].name = 'mutable'; output.push(bytePacket(new Uint8Array()));
    assert.deepEqual(bytes, new Uint8Array([0, 128, 255]));
    equalByteBatch(await invoke(name, []), []);
    equalByteBatch(await invoke(name, [bytePacket(new Uint8Array())]), [bytePacket(new Uint8Array())]);
    if (name.startsWith('echoNullable')) {
      assert.equal(await invoke(name, null), null);
      equalByteBatch(await invoke(name, [null, bytePacket(new Uint8Array([1]))]), [null, bytePacket(new Uint8Array([1]))]);
    } else await failure(name, [null], TypeError, ['parameter values']);
    await failure(name, [[bytePacket(new Uint8Array([1])), { name: 'missing' }]], TypeError, ['parameter values[1]["payload"]']);
    await failure(name, [[bytePacket(new Uint8Array([1])), bytePacket(undefined)]], TypeError, ['parameter values[1]["payload"]']);
  }
  for (const name of ['echoPackets', 'echoPacketsAsync']) {
    const bytes = Buffer.from([99, 0, 128, 255, 88]).subarray(1, 4);
    equalByteBatch(await invoke(name, [bytePacket(bytes)]), [bytePacket(new Uint8Array([0, 128, 255]))]);
    const foreign = runInNewContext("[{name:'foreign',payload:new Uint8Array([0,128,255])}]");
    equalByteBatch(await invoke(name, foreign), [{ name: 'foreign', payload: new Uint8Array([0, 128, 255]) }]);
    let byteGetters = 0;
    const hidden = Object.create(null);
    Object.defineProperties(hidden, { name: { value: 'hidden' }, payload: { value: new Uint8Array([1]) } });
    equalByteBatch(await invoke(name, [hidden]), [{ name: 'hidden', payload: new Uint8Array([1]) }]);
    const accessor = bytePacket(new Uint8Array([1]));
    Object.defineProperty(accessor, 'payload', { get() { byteGetters++; return new Uint8Array([1]); } });
    await failure(name, [[bytePacket(new Uint8Array([1])), accessor]], TypeError, ['parameter values[1]["payload"]']);
    const view = new Uint8Array([1]);
    for (const key of ['length', 'byteLength', 'byteOffset', 'buffer', Symbol.iterator, Symbol.toStringTag]) {
      Object.defineProperty(view, key, { get() { byteGetters++; throw Error('unused byte-view getter'); } });
    }
    const extra = bytePacket(view);
    Object.defineProperty(extra, 'ignored', { get() { byteGetters++; throw Error('unused byte-row getter'); } });
    const proxy = new Proxy(extra, {
      get() { throw Error('must not read row getters'); },
      ownKeys() { throw Error('must not enumerate row extras'); },
      getOwnPropertyDescriptor(target, key) {
        assert(['name', 'payload'].includes(key));
        return Reflect.getOwnPropertyDescriptor(target, key);
      },
    });
    equalByteBatch(await invoke(name, [proxy]), [bytePacket(new Uint8Array([1]))]);
    assert.equal(byteGetters, 0);
    for (const payload of [null, new Uint16Array(1), new DataView(new ArrayBuffer(1)), new ArrayBuffer(1), [], new Proxy(new Uint8Array(1), {})]) {
      await failure(name, [[bytePacket(new Uint8Array([1])), bytePacket(payload)]], TypeError, ['parameter values[1]["payload"]']);
    }
    const detached = new Uint8Array([1]);
    structuredClone(detached.buffer, { transfer: [detached.buffer] });
    await failure(name, [[bytePacket(new Uint8Array([1])), bytePacket(detached)]], TypeError, ['parameter values[1]["payload"]']);
    const rab = new ArrayBuffer(8, { maxByteLength: 16 });
    const oob = new Uint8Array(rab, 2, 3); rab.resize(1);
    await failure(name, [[bytePacket(new Uint8Array([1])), bytePacket(oob)]], TypeError, ['parameter values[1]["payload"]']);
    for (const reason of [new Error('byte row reflection'), new TypeError('byte row reflection type'), new RangeError('byte row reflection range'), 'byte reason', Symbol('byte reason')]) {
      await identicalFailure(name, [bytePacket(new Uint8Array([1])), new Proxy(bytePacket(new Uint8Array([1])), { getOwnPropertyDescriptor() { throw reason; } })], reason);
      await identicalFailure(name, new Proxy([bytePacket(new Uint8Array([1]))], { getOwnPropertyDescriptor() { throw reason; } }), reason);
    }
  }
  for (const name of ['normalizePackets', 'normalizePacketsAsync']) {
    const bytes = new Uint8Array([0, 128, 255]);
    const input = [{ name: ' sample ', payload: bytes }];
    const pending = invoke(name, input);
    assert.deepEqual(bytes, new Uint8Array([0, 128, 255]), 'Dart business mutates only its owned payload');
    bytes.fill(7); input[0].name = 'changed'; input[0].payload = new Uint8Array([8]); input.push(bytePacket(new Uint8Array([9])));
    equalByteBatch(await pending, [{ name: 'sample', payload: new Uint8Array([255, 127, 0]) }]);
    assert.deepEqual(bytes, new Uint8Array([7, 7, 7]));
  }
  for (const name of ['echoInlinePackets', 'echoInlinePacketsAsync']) {
    equalByteBatch(await invoke(name, [bytePacket(new Uint8Array([1])), { name: 'nullable', payload: null }, null]), [bytePacket(new Uint8Array([1])), { name: 'nullable', payload: null }, null]);
    assert.equal(await invoke(name, null), null);
    await failure(name, [[bytePacket(new Uint8Array([1])), { name: 'missing' }]], TypeError, ['parameter values[1]["payload"]']);
  }
  for (const name of ['echoPartPackets', 'echoPartPacketsAsync']) {
    equalByteBatch(await invoke(name, [{ code: 1, payload: new Uint8Array([1]) }, { code: 2, payload: null }, null]), [{ code: 1, payload: new Uint8Array([1]) }, { code: 2, payload: null }, null]);
    assert.equal(await invoke(name, null), null);
  }
  for (const name of ['echoByteFieldsList', 'echoByteFieldsListAsync']) {
    const bytes = new Uint8Array([1, 2]);
    const row = { first: bytes, maybe: bytes, second: bytes };
    const output = await invoke(name, [row, row]);
    equalByteBatch(output, [row, row]);
    const fields = output.flatMap(value => [value.first, value.maybe, value.second]);
    assert.equal(new Set(fields.map(value => value.buffer)).size, fields.length, 'each output field and position owns separate byte storage');
    output[0].first[0] = 9;
    for (const field of fields.slice(1)) assert.equal(field[0], 1);
    assert.equal(bytes[0], 1);
    const before = invoke('calls');
    await failure(name, [[row, row, { first: bytes, maybe: null, second: undefined }]], TypeError, ['parameter values[2]["second"]']);
    assert.equal(invoke('calls'), before, 'later-row byte failure prevents business entry');
  }
  for (const name of ['echoPackets', 'echoPacketsAsync', 'repeatFirstPacket', 'repeatFirstPacketAsync']) {
    const shared = bytePacket(new Uint8Array([1, 2]));
    const output = await invoke(name, [shared, shared]);
    equalByteBatch(output, [shared, shared]);
    assert.notEqual(output[0], output[1]);
    assert.notEqual(output[0].payload.buffer, output[1].payload.buffer);
    assert.notEqual(output[0].payload.buffer, shared.payload.buffer);
    output[0].payload[0] = 9;
    assert.equal(output[1].payload[0], 1); assert.equal(shared.payload[0], 1);
  }
  for (const name of ['trackedPackets', 'trackedPacketsAsync']) {
    for (const second of [[bytePacket(new Uint8Array([1])), bytePacket(undefined)], [bytePacket(new Uint8Array([1])), bytePacket(new Uint16Array(1))]]) {
      const before = invoke('calls');
      await failure(name, [[bytePacket(new Uint8Array([1]))], second], TypeError, ['parameter second[1]["payload"]']);
      assert.equal(invoke('calls'), before);
    }
    const bad = new Uint8Array([1]); structuredClone(bad.buffer, { transfer: [bad.buffer] });
    const before = invoke('calls');
    await failure(name, [[bytePacket(new Uint8Array([1])), bytePacket(bad)], []], TypeError, ['parameter first[1]["payload"]']);
    assert.equal(invoke('calls'), before);
    const firstBytes = new Uint8Array([1, 2]); const secondBytes = new Uint8Array([3, 4]);
    const first = [bytePacket(firstBytes)]; const second = [{ name: 'second', payload: secondBytes }];
    const pending = invoke(name, first, second);
    firstBytes.fill(7); first[0].payload = new Uint8Array([8]); first.length = 0;
    structuredClone(secondBytes.buffer, { transfer: [secondBytes.buffer] }); second[0].payload = new Uint8Array([8]); second.length = 0;
    equalByteBatch(await pending, [{ name: 'second', payload: new Uint8Array([3, 4]) }]);
    const saved = invoke('readPackets');
    equalByteBatch(saved, [bytePacket(new Uint8Array([1, 2]))]);
    saved[0].payload[0] = 9; saved.push(bytePacket(new Uint8Array([9])));
    equalByteBatch(await invoke('readPacketsAsync'), [bytePacket(new Uint8Array([1, 2]))]);
    const previous = invoke('readPackets'); invoke('changePackets');
    equalByteBatch(previous, [bytePacket(new Uint8Array([1, 2]))]);
    const changed = invoke('readPackets');
    equalByteBatch(changed, [bytePacket(new Uint8Array([254, 2])), bytePacket(new Uint8Array([254, 2]))]);
    assert.notEqual(changed[0].payload.buffer, changed[1].payload.buffer);
    assert.deepEqual(firstBytes, new Uint8Array([7, 7]));
    await failure(name, [[{ name: 'fail', payload: new Uint8Array([1]) }], [bytePacket(new Uint8Array([2]))]], TypeError, ['packet failure']);
    equalByteBatch(await invoke(name, [bytePacket(new Uint8Array([1]))], [bytePacket(new Uint8Array([2]))]), [bytePacket(new Uint8Array([2]))]);
  }

  // Discarded arrays, records, and unique strings must not become boundary roots.
  assert.equal(typeof global.gc, 'function', 'run with --expose-gc');
  const retainedOutputs = [];
  const retainedByteOutputs = [];
  const leakProbe = process.env.NAPI_BATCH_RETAIN_OUTPUTS === '1';
  const codeUnits = new Uint16Array(8192);
  codeUnits.fill(0x4e2d);
  let batchId = 0;
  async function batch() {
    const id = batchId++;
    for (let index = 0; index < 512; index++) {
      const input = [];
      for (let row = 0; row < 4; row++) {
        codeUnits[0] = id; codeUnits[1] = index; codeUnits[2] = row;
        input.push({ name: String.fromCharCode(...codeUnits), age: index * 4 + row, active: null });
      }
      const output = invoke('echoUsers', input);
      assert.equal(output.length, 4);
      assert.equal(output[3].name, input[3].name);
      assert.equal(output[3].age, index * 4 + 3);
      if (leakProbe) retainedOutputs.push(output);
      const byteOutput = invoke('echoPackets', input.map(row => ({ name: row.name, payload: new Uint8Array(8192) })));
      assert.equal(byteOutput[3].payload.length, 8192);
      if (leakProbe) retainedByteOutputs.push(byteOutput);
    }
    for (let index = 0; index < 16; index += 4) {
      await Promise.all(Array.from({ length: 4 }, (_, offset) => invoke('echoUsersAsync', [{ name: `batch ${id}`, age: index + offset, active: null }])));
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
  assert.equal(retainedOutputs.length, leakProbe ? 1024 : 0);
  assert.equal(retainedByteOutputs.length, leakProbe ? 1024 : 0);
  await immediate(); await immediate();
  assert.deepEqual(unhandled, [], 'record-list errors must not escape Promise settlement');
  console.log(JSON.stringify({ checks, nativeFunctions: names.length, node: process.version, retained }));
} finally {
  process.removeListener('unhandledRejection', onUnhandled);
  process.removeListener('uncaughtException', onUnhandled);
}
