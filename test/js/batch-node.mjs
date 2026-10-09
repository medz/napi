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
  'invalidLengthUsers', 'invalidLengthUsersAsync', 'invalidIndexReads',
];
for (const name of names) {
  assert.equal(typeof api[name], 'function', name);
  assert.equal(api[name], subpath[name], `${name} package subpath`);
  assert.equal(api[name], relative[name], `${name} relative raw Wasm`);
  assert.match(Function.prototype.toString.call(api[name]), /\[native code\]/, name);
}
for (const name of ['User', 'UserAlias', 'MaybeUserAlias', 'Mixed', 'SpecialFields', 'BatchPart']) {
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
      equalBatch(await invoke(name, Object.freeze(input)), input);
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

  // Discarded arrays, records, and unique strings must not become boundary roots.
  assert.equal(typeof global.gc, 'function', 'run with --expose-gc');
  const retainedOutputs = [];
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
  await immediate(); await immediate();
  assert.deepEqual(unhandled, [], 'record-list errors must not escape Promise settlement');
  console.log(JSON.stringify({ checks, nativeFunctions: names.length, node: process.version, retained }));
} finally {
  process.removeListener('unhandledRejection', onUnhandled);
  process.removeListener('uncaughtException', onUnhandled);
}
