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
];
for (const name of names) {
  assert.equal(typeof api[name], 'function', name);
  assert.equal(api[name], subpath[name], `${name} package subpath`);
  assert.equal(api[name], relative[name], `${name} relative raw Wasm`);
  assert.match(Function.prototype.toString.call(api[name]), /\[native code\]/, name);
}
for (const name of ['UserAlias', 'NullableUser', 'MaybeUserAlias', 'ReexportUser', 'Mixed', 'SpecialFields', 'PartValue']) {
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
  try {
    await invoke(name, ...args);
  } catch (error) {
    caught = true;
    assert(error instanceof type, `${name}: ${error?.constructor?.name}: ${error?.message}`);
    for (const part of context) assert(error.message.includes(part), `${name}: ${error.message} lacks ${part}`);
  }
  assert(caught, `${name} must fail`);
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
        await failure(name, [{ ...mixed(), [key]: value }], TypeError, ['parameter value', `["${key}"]`]);
      }
      const missing = mixed();
      delete missing[key];
      await failure(name, [missing], TypeError, ['parameter value', `["${key}"]`]);
    }
    for (const key of ['count', 'maybeCount']) {
      for (const value of [Number.MIN_SAFE_INTEGER - 1, Number.MAX_SAFE_INTEGER + 1]) {
        await failure(name, [{ ...mixed(), [key]: value }], RangeError, ['parameter value', `["${key}"]`]);
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
  for (const name of ['echoSpecial', 'echoSpecialAsync']) equalRecord(await invoke(name, special), special);

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
  for (const name of ['unsafeUser', 'unsafeUserAsync']) await failure(name, [], RangeError, ['result', '["age"]']);
  for (const name of ['unsafeMixed', 'unsafeMixedAsync']) await failure(name, [], RangeError, ['result', '["count"]']);

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

  // Repeated discarded strings/objects must not become retained boundary state.
  assert.equal(typeof global.gc, 'function', 'run with --expose-gc');
  const retainedOutputs = [];
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
  await immediate(); await immediate();
  assert.deepEqual(unhandled, [], 'record errors must not escape Promise settlement');
  console.log(JSON.stringify({ checks, nativeFunctions: names.length, node: process.version, retained }));
} finally {
  process.removeListener('unhandledRejection', onUnhandled);
  process.removeListener('uncaughtException', onUnhandled);
}
