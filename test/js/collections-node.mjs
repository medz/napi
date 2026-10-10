import assert from 'node:assert/strict';
import { setImmediate as immediate } from 'node:timers/promises';
import { runInNewContext } from 'node:vm';
import * as api from '@napi/collections';
import * as subpath from '@napi/collections/module.wasm';
import * as relative from './dist/module.wasm';
import { listInt, invertAll } from './dist/module.wasm';

const scalars = [
  ['Bool', [false, true], [1, '', {}, new Boolean(true)]],
  ['Int', [0, -42, Number.MIN_SAFE_INTEGER, Number.MAX_SAFE_INTEGER], [1.5, NaN, Infinity, 1n, {}]],
  ['Double', [0, -0, 0.125, NaN, Infinity, -Infinity], [true, 1n, new Number(1)]],
  ['String', ['', '你好🚀', 'a\0b', '\ud800', '\udfff', '\ud800x\udfff'], [1, new String('boxed'), Symbol('text'), {}]],
];
const variants = [
  ['', false, false], ['Nullable', false, true],
  ['NullableContainer', true, false], ['NullableBoth', true, true],
];
const identities = [];
for (const [prefix] of variants) {
  identities.push(`list${prefix}Bytes`, `list${prefix}BytesAsync`);
}
for (const container of ['list', 'map']) {
  for (const [scalar] of scalars) {
    for (const [prefix] of variants) {
      identities.push(`${container}${prefix}${scalar}`, `${container}${prefix}${scalar}Async`);
    }
  }
}
const names = [...identities, 'calls', 'trackedList', 'trackedListAsync',
  'trackedMap', 'trackedMapAsync', 'readList', 'readListAsync', 'readMap',
  'readMapAsync', 'changeRetained', 'unsafeList', 'unsafeListAsync', 'unsafeMap', 'unsafeMapAsync',
  'formatterRangeList', 'formatterRangeListAsync', 'formatterTypeList', 'formatterTypeListAsync',
  'formatterRangeMap', 'formatterRangeMapAsync', 'formatterTypeMap', 'formatterTypeMapAsync',
  'invertAll', 'invertAllAsync', 'trackedBytes', 'trackedBytesAsync', 'readBytes', 'readBytesAsync',
  'failingBytes', 'failingBytesAsync'];
for (const name of names) {
  assert.equal(typeof api[name], 'function', name);
  assert.equal(api[name], subpath[name], `${name} package subpath`);
  assert.equal(api[name], relative[name], `${name} relative raw Wasm`);
  assert.match(Function.prototype.toString.call(api[name]), /\[native code\]/, `${name} raw function`);
}
assert.equal(listInt, api.listInt);
assert.equal(invertAll, api.invertAll);

let checks = 0;
function invoke(name, ...args) {
  checks++;
  if (!name.endsWith('Async')) return api[name](...args);
  let promise;
  assert.doesNotThrow(() => { promise = api[name](...args); }, `${name} returns rather than throws`);
  assert(promise instanceof Promise, `${name} returns a real Promise`);
  return bounded(promise);
}
async function bounded(promise) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error('Collection Promise did not settle')), 3000);
    })]);
  } finally {
    clearTimeout(timer);
  }
}
async function failure(name, args, type, context) {
  let caught = false;
  try {
    await invoke(name, ...args);
  } catch (error) {
    caught = true;
    assert(error instanceof type, `${name}: ${error?.constructor?.name}: ${error?.message}`);
    for (const part of context ?? []) assert(error.message.includes(part), `${name}: ${error.message} lacks ${part}`);
  }
  assert(caught, `${name} must fail`);
}
function equalMap(actual, expected) {
  assert.equal(Object.getPrototypeOf(actual), null, 'result map has null prototype');
  assert.deepEqual(Object.keys(actual).sort(), Object.keys(expected).sort());
  for (const key of Object.keys(expected)) {
    assert(Object.hasOwn(actual, key));
    assert(Object.is(actual[key], expected[key]), `map value at ${JSON.stringify(key)}`);
    assert(Object.hasOwn(Object.getOwnPropertyDescriptor(actual, key), 'value'));
  }
}
function equalList(actual, expected) {
  assert(Array.isArray(actual));
  assert.deepEqual(actual, expected);
  for (let i = 0; i < actual.length; i++) {
    assert(Object.hasOwn(actual, i));
    assert(Object.hasOwn(Object.getOwnPropertyDescriptor(actual, i), 'value'));
  }
}
function equalBytes(actual, expected) {
  assert(Array.isArray(actual));
  assert.equal(actual.length, expected.length);
  for (let index = 0; index < expected.length; index++) {
    assert(Object.hasOwn(Object.getOwnPropertyDescriptor(actual, index), 'value'));
    if (expected[index] === null) {
      assert.equal(actual[index], null);
    } else {
      assert(actual[index] instanceof Uint8Array);
      assert(actual[index].buffer instanceof ArrayBuffer);
      assert.equal(actual[index].buffer.resizable, false);
      assert.deepEqual(Array.from(actual[index]), Array.from(expected[index]));
    }
  }
}

const unhandled = [];
const onUnhandled = error => unhandled.push(error);
process.on('unhandledRejection', onUnhandled);
process.on('uncaughtException', onUnhandled);
try {
  // Every scalar, container/leaf nullability combination, and sync/Future path.
  for (const container of ['list', 'map']) {
    for (const [scalar, valid, invalid] of scalars) {
      for (const [prefix, nullableContainer, nullableLeaf] of variants) {
        for (const suffix of ['', 'Async']) {
          const name = `${container}${prefix}${scalar}${suffix}`;
          const leaves = [...valid, ...(nullableLeaf ? [null] : [])];
          const input = container === 'list' ? leaves : Object.fromEntries(leaves.map((v, i) => [`v${i}`, v]));
          const result = await invoke(name, input);
          assert.notEqual(result, input);
          if (container === 'list') equalList(result, leaves);
          else equalMap(result, input);
          const empty = container === 'list' ? [] : Object.create(null);
          const emptyResult = await invoke(name, empty);
          assert.notEqual(emptyResult, empty);
          if (container === 'list') equalList(emptyResult, []);
          else equalMap(emptyResult, empty);
          if (nullableContainer) assert.equal(await invoke(name, null), null);
          else await failure(name, [null], TypeError, ['parameter values']);
          await failure(name, [undefined], TypeError, ['parameter values']);
          await failure(name, [], TypeError, ['parameter values']);
          for (const bad of [undefined, ...invalid, ...(nullableLeaf ? [] : [null])]) {
            await failure(name, [container === 'list' ? [bad] : { bad }], TypeError,
              ['parameter values', container === 'list' ? '[0]' : '["bad"]']);
          }
          if (scalar === 'Int') {
            for (const value of [Number.MAX_SAFE_INTEGER + 1, Number.MIN_SAFE_INTEGER - 1]) {
              await failure(name, [container === 'list' ? [1, value] : { good: 1, bad: value }], RangeError,
                ['parameter values', container === 'list' ? '[1]' : '["bad"]']);
            }
          }
        }
      }
    }
  }

  // Byte Lists compose dense Array snapshots with owned storage at every slot.
  for (const [prefix, nullableContainer, nullableLeaf] of variants) {
    for (const suffix of ['', 'Async']) {
      const name = `list${prefix}Bytes${suffix}`;
      const bytes = new Uint8Array([0, 128, 255]);
      const input = Object.freeze([bytes, bytes, new Uint8Array(), ...(nullableLeaf ? [null] : [])]);
      const output = await invoke(name, input);
      equalBytes(output, input);
      assert.notEqual(output, input);
      assert.notEqual(output[0].buffer, bytes.buffer);
      assert.notEqual(output[0].buffer, output[1].buffer);
      output[0][0] = 9; output.push(new Uint8Array([7]));
      assert.equal(output[1][0], 0); assert.equal(bytes[0], 0);
      const empty = Object.freeze([]);
      const emptyOutput = await invoke(name, empty);
      equalBytes(emptyOutput, []); assert.notEqual(emptyOutput, empty);
      if (nullableContainer) assert.equal(await invoke(name, null), null);
      else await failure(name, [null], TypeError, ['parameter values']);
      await failure(name, [undefined], TypeError, ['parameter values']);
      await failure(name, [], TypeError, ['parameter values']);
      await failure(name, [[bytes, undefined]], TypeError, ['parameter values[1]']);
      if (!nullableLeaf) await failure(name, [[bytes, null]], TypeError, ['parameter values[1]']);
    }
  }
  let byteGetterCalls = 0;
  for (const suffix of ['', 'Async']) {
    const name = `listBytes${suffix}`;
    const bytes = new Uint8Array([1]);
    const accessor = [bytes, bytes];
    Object.defineProperty(accessor, '1', { get() { byteGetterCalls++; return bytes; } });
    const inherited = [bytes, , bytes];
    Object.setPrototypeOf(inherited, Object.assign(Object.create(Array.prototype), { 1: bytes }));
    for (const input of [[bytes, , bytes], accessor, inherited]) {
      await failure(name, [input], TypeError, ['parameter values[1]']);
    }
    await failure(name, [bytes], TypeError, ['parameter values']);
    for (const bad of [new Uint16Array(1), new DataView(new ArrayBuffer(1)), new ArrayBuffer(1), [], new Proxy(bytes, {})]) {
      await failure(name, [[bytes, bad]], TypeError, ['parameter values[1]']);
    }
    const detached = new Uint8Array([2]);
    structuredClone(detached.buffer, { transfer: [detached.buffer] });
    await failure(name, [[bytes, detached]], TypeError, ['parameter values[1]']);
    const resizable = new ArrayBuffer(8, { maxByteLength: 16 });
    const offset = new Uint8Array(resizable, 2, 3); offset.set([0, 128, 255]);
    equalBytes(await invoke(name, [offset]), [new Uint8Array([0, 128, 255])]);
    resizable.resize(1);
    await failure(name, [[bytes, offset]], TypeError, ['parameter values[1]']);
    const shared = new Uint8Array(new SharedArrayBuffer(3)); shared.set([0, 128, 255]);
    equalBytes(await invoke(name, [shared]), [new Uint8Array([0, 128, 255])]);
    const buffer = Buffer.from([99, 0, 128, 255, 88]).subarray(1, 4);
    equalBytes(await invoke(name, [buffer]), [new Uint8Array([0, 128, 255])]);
    const foreign = runInNewContext('[new Uint8Array([0, 128, 255])]');
    equalBytes(await invoke(name, foreign), [new Uint8Array([0, 128, 255])]);
    const extra = [bytes];
    Object.defineProperty(extra, 'ignored', { get() { byteGetterCalls++; throw Error('array extra'); } });
    for (const key of ['length', 'byteLength', 'byteOffset', 'buffer', Symbol.iterator, Symbol.toStringTag]) {
      Object.defineProperty(bytes, key, { get() { byteGetterCalls++; throw Error('byte getter'); } });
    }
    equalBytes(await invoke(name, extra), [new Uint8Array([1])]);
    const original = new TypeError('byte List reflection');
    await assert.rejects(async () => invoke(name, new Proxy([bytes], {
      getOwnPropertyDescriptor() { throw original; },
    })), error => error === original);
  }
  assert.equal(byteGetterCalls, 0);
  for (const suffix of ['', 'Async']) {
    await failure(`failingBytes${suffix}`, [2], RangeError, ['result[1]', 'byte getter']);
    for (const length of [-1, 0x100000000]) {
      await failure(`failingBytes${suffix}`, [length], RangeError, ['result']);
    }
    const bytes = new Uint8Array([0, 128, 255]);
    const pending = invoke(`invertAll${suffix}`, [bytes, bytes]);
    assert.deepEqual(bytes, new Uint8Array([0, 128, 255]), 'Dart mutation uses independent input copies');
    equalBytes(await pending, [new Uint8Array([255, 127, 0]), new Uint8Array([255, 127, 0])]);
    const name = `trackedBytes${suffix}`;
    const before = invoke('calls');
    await failure(name, [[bytes, undefined], []], TypeError, ['parameter first[1]']);
    await failure(name, [[bytes], [bytes, new Uint16Array(1)]], TypeError, ['parameter second[1]']);
    assert.equal(invoke('calls'), before, 'every byte List argument validates before business entry');
    const firstBytes = new Uint8Array([1, 2]); const secondBytes = new Uint8Array([3, 4]);
    const first = [firstBytes]; const second = [secondBytes];
    const result = invoke(name, first, second);
    firstBytes.fill(7); first.length = 0;
    structuredClone(secondBytes.buffer, { transfer: [secondBytes.buffer] }); second.length = 0;
    equalBytes(await result, [new Uint8Array([3, 4])]);
    const saved = await invoke(`readBytes${suffix}`);
    equalBytes(saved, [new Uint8Array([1, 2])]);
    saved[0][0] = 9; saved.push(new Uint8Array([9]));
    equalBytes(await invoke(`readBytes${suffix}`), [new Uint8Array([1, 2])]);
    const previous = invoke('readBytes'); invoke('changeRetained');
    equalBytes(previous, [new Uint8Array([1, 2])]);
    const duplicated = await invoke(`readBytes${suffix}`);
    equalBytes(duplicated, [new Uint8Array([254, 2]), new Uint8Array([254, 2])]);
    assert.notEqual(duplicated[0].buffer, duplicated[1].buffer, 'repeated Dart references copy on every output slot');
    duplicated[0][0] = 8; assert.equal(duplicated[1][0], 254);
  }
  // Owned-copy TypeErrors carry an index; other JS reasons retain identity.
  const byteInput = [new Uint8Array([1]), new Uint8Array([2])];
  const OriginalUint8Array = globalThis.Uint8Array;
  try {
    for (const suffix of ['', 'Async']) {
      const copyError = new TypeError('byte List copy');
      let copies = 0;
      globalThis.Uint8Array = class extends OriginalUint8Array {
        constructor(...args) { if (++copies === 2) throw copyError; super(...args); }
      };
      await failure(`listBytes${suffix}`, [byteInput], TypeError, ['parameter values[1]', 'byte List copy']);
      globalThis.Uint8Array = class { constructor() { throw copyError; } };
      await failure(`readBytes${suffix}`, [], TypeError, ['result[0]', 'byte List copy']);
      const original = new RangeError('byte List original');
      globalThis.Uint8Array = class { constructor() { throw original; } };
      await assert.rejects(async () => invoke(`listBytes${suffix}`, byteInput), error => error === original);
    }
  } finally {
    globalThis.Uint8Array = OriginalUint8Array;
  }
  equalBytes(await invoke('listBytesAsync', byteInput), byteInput);

  // Own dense indices only. Extra named/symbol properties are ignored.
  let getterCalls = 0;
  const accessor = [1, 2];
  Object.defineProperty(accessor, '1', { get() { getterCalls++; return 2; } });
  const inherited = [1, , 3];
  Object.setPrototypeOf(inherited, Object.assign(Object.create(Array.prototype), { 1: 2 }));
  const extra = [1, 2];
  Object.defineProperty(extra, 'ignored', { enumerable: true, get() { getterCalls++; throw Error('ignored'); } });
  extra[Symbol('ignored')] = {};
  extra['01'] = {};
  for (const suffix of ['', 'Async']) {
    const name = `listInt${suffix}`;
    for (const input of [[1, , 3], inherited, accessor]) await failure(name, [input], TypeError, ['parameter values', '[1]']);
    for (const input of [new Uint8Array([1]), new Int32Array([1]), { 0: 1, length: 1 }, '1', new Set([1])]) {
      await failure(name, [input], TypeError, ['parameter values']);
    }
    equalList(await invoke(name, extra), [1, 2]);
    const frozen = Object.freeze([1, 2]);
    const copied = await invoke(name, frozen);
    equalList(copied, [1, 2]);
    assert.notEqual(copied, frozen);
    assert.equal(Object.isFrozen(copied), false);
    copied[0] = 7;
    copied.push(3);
    assert.deepEqual(frozen, [1, 2]);
    const nullableFrozen = Object.freeze([1, null]);
    const nullableCopied = await invoke(`listNullableBothInt${suffix}`, nullableFrozen);
    equalList(nullableCopied, [1, null]);
    assert.notEqual(nullableCopied, nullableFrozen);
    assert.equal(Object.isFrozen(nullableCopied), false);
    nullableCopied[0] = null;
    nullableCopied.push(2);
    assert.deepEqual(nullableFrozen, [1, null]);
  }
  for (const suffix of ['', 'Async']) {
    for (const length of ['0', null, -1, 1.5]) {
      const input = new Proxy([], {
        getOwnPropertyDescriptor(target, key) {
          const descriptor = Reflect.getOwnPropertyDescriptor(target, key);
          return key === 'length' ? { ...descriptor, value: length } : descriptor;
        },
      });
      await failure(`listInt${suffix}`, [input], typeof length === 'number' ? RangeError : TypeError, ['parameter values']);
    }
  }
  assert.equal(getterCalls, 0, 'array accessors are never invoked');

  // Cross-realm branding, including values that JSON would lose or alter.
  const foreignValues = [
    ['Bool', '[false, true]', '({a:false,b:true})'],
    ['Int', '[Number.MIN_SAFE_INTEGER, Number.MAX_SAFE_INTEGER]', '({a:Number.MIN_SAFE_INTEGER,b:Number.MAX_SAFE_INTEGER})'],
    ['Double', '[NaN, -0, Infinity, -Infinity]', '({a:NaN,b:-0,c:Infinity,d:-Infinity})'],
    ['String', "['你好🚀','\\ud800','a\\0b']", "({a:'你好🚀',b:'\\ud800',c:'a\\0b'})"],
  ];
  for (const [scalar, arraySource, objectSource] of foreignValues) {
    const array = runInNewContext(arraySource);
    const object = runInNewContext(objectSource);
    for (const suffix of ['', 'Async']) {
      equalList(await invoke(`list${scalar}${suffix}`, array), Array.from(array));
      equalMap(await invoke(`map${scalar}${suffix}`, object), object);
    }
  }

  // Ordinary and null-prototype maps preserve hostile/special UTF-16 keys.
  const keys = ['__proto__', 'constructor', 'prototype', 'toString', 'then', '',
    '0', '01', '4294967295', '你好', 'a\0b', '\ud800', '\udfff'];
  const special = Object.create(null);
  for (const key of keys) special[key] = `value:${key}`;
  const accessorMap = { good: 'ok' };
  Object.defineProperty(accessorMap, 'bad', { enumerable: true, get() { getterCalls++; return 'bad'; } });
  const extraMap = { good: 'ok' };
  Object.defineProperty(extraMap, 'ignored', { get() { getterCalls++; throw Error('ignored'); } });
  extraMap[Symbol('ignored')] = {};
  const inheritedKey = 'napiCollectionInherited';
  Object.defineProperty(Object.prototype, inheritedKey, { configurable: true, enumerable: true, get() { getterCalls++; throw Error('inherited'); } });
  try {
    for (const suffix of ['', 'Async']) {
      const name = `mapString${suffix}`;
      equalMap(await invoke(name, special), special);
      equalMap(await invoke(name, Object.fromEntries(Object.entries(special))), special);
      equalMap(await invoke(name, extraMap), { good: 'ok' });
      await failure(name, [accessorMap], TypeError, ['parameter values', '["bad"]']);
    }
  } finally {
    delete Object.prototype[inheritedKey];
  }
  // Local ordinary objects remain ordinary when inherited constructor changes.
  const constructorDescriptor = Object.getOwnPropertyDescriptor(Object.prototype, 'constructor');
  try {
    delete Object.prototype.constructor;
    for (const suffix of ['', 'Async']) equalMap(await invoke(`mapString${suffix}`, { good: 'ok' }), { good: 'ok' });
    Object.defineProperty(Object.prototype, 'constructor', {
      configurable: true, get() { getterCalls++; throw Error('constructor getter'); },
    });
    for (const suffix of ['', 'Async']) equalMap(await invoke(`mapString${suffix}`, { good: 'ok' }), { good: 'ok' });
  } finally {
    Object.defineProperty(Object.prototype, 'constructor', constructorDescriptor);
  }
  assert.equal(getterCalls, 0, 'map own/inherited/non-enumerable accessors are never invoked');
  class RecordClass { constructor() { this.a = 1; } }
  const custom = Object.create({ inherited: 1 });
  custom.a = 1;
  const forged = Object.create(Object.create(null, { constructor: { value: Object } }));
  forged.a = 1;
  const invalidMaps = [new RecordClass(), custom, forged, [], new Uint8Array([1]),
    new Date(), new Map([['a', 1]]), new Set([1]), new Number(1), Object.create([])];
  for (const suffix of ['', 'Async']) {
    for (const value of invalidMaps) await failure(`mapInt${suffix}`, [value], TypeError, ['parameter values']);
    const cycleList = []; cycleList.push(cycleList);
    const cycleMap = {}; cycleMap.self = cycleMap;
    await failure(`listInt${suffix}`, [cycleList], TypeError, ['parameter values', '[0]']);
    await failure(`mapInt${suffix}`, [cycleMap], TypeError, ['parameter values', '["self"]']);
  }

  // Full validation of every argument precedes business-side effects.
  for (const suffix of ['', 'Async']) {
    let before = invoke('calls');
    await failure(`trackedList${suffix}`, [[1, 2, undefined], { ok: 1 }], TypeError, ['parameter values', '[2]']);
    assert.equal(invoke('calls'), before);
    await failure(`trackedList${suffix}`, [[1, 2], { first: 1, late: undefined }], TypeError, ['parameter labels', '["late"]']);
    assert.equal(invoke('calls'), before);
    await failure(`trackedMap${suffix}`, [{ first: 'ok', late: undefined }, [1]], TypeError, ['parameter values', '["late"]']);
    assert.equal(invoke('calls'), before);
    await failure(`trackedMap${suffix}`, [{ stored: 'ok' }, [1, undefined]], TypeError, ['parameter markers', '[1]']);
    assert.equal(invoke('calls'), before);
    await failure(`unsafeList${suffix}`, [], RangeError, ['result', '[1]']);
    await failure(`unsafeMap${suffix}`, [], RangeError, ['result', '["bad"]']);
    equalList(await invoke(`listInt${suffix}`, [42]), [42]);
  }

  // Errors originate while reading returned SDK collections, not in business code.
  for (const suffix of ['', 'Async']) {
    await failure(`formatterRangeList${suffix}`, [], RangeError, ['result', '[0]', 'formatting failed']);
    await failure(`formatterTypeList${suffix}`, [], TypeError, ['result', '[0]', 'toString failed']);
    // MapBase builds entries lazily; an index read fails before its key exists.
    await failure(`formatterRangeMap${suffix}`, [], RangeError, ['result', 'formatting failed']);
    await failure(`formatterTypeMap${suffix}`, [], TypeError, ['result', 'toString failed']);
    equalList(await invoke(`listInt${suffix}`, [42]), [42]);
    equalMap(await invoke(`mapInt${suffix}`, { good: 42 }), { good: 42 });
  }

  // Snapshot inputs before returning the Promise; outputs never share storage.
  const snapshots = [];
  for (const suffix of ['', 'Async']) {
    const list = [1, 2];
    const listResult = invoke(`trackedList${suffix}`, list, { label: 1 });
    list[0] = 9; list.push(3);
    equalList(await listResult, [1, 2]);
    const storedList = await invoke(`readList${suffix}`);
    storedList[0] = 100;
    equalList(await invoke(`readList${suffix}`), [1, 2]);
    snapshots.push(await invoke(`readList${suffix}`));
    const object = Object.assign(Object.create(null), { stored: 'original', maybe: null });
    const objectResult = invoke(`trackedMap${suffix}`, object, [1]);
    object.stored = 'caller mutation'; delete object.maybe; object.new = 'added';
    equalMap(await objectResult, { stored: 'original', maybe: null });
    const storedMap = await invoke(`readMap${suffix}`);
    storedMap.stored = 'output mutation';
    equalMap(await invoke(`readMap${suffix}`), { stored: 'original', maybe: null });
    const retained = await invoke(`readMap${suffix}`);
    invoke('changeRetained');
    equalMap(retained, { stored: 'original', maybe: null });
    equalList(snapshots.at(-1), [1, 2]);
  }
  const reflectInputs = [1, 2];
  let reflected = 0;
  const reflectedPromise = invoke('listIntAsync', new Proxy(reflectInputs, {
    getOwnPropertyDescriptor(target, key) { reflected++; return Reflect.getOwnPropertyDescriptor(target, key); },
  }));
  assert(reflected >= 2, 'async input reflection happens before returning its Promise');
  reflectInputs.fill(8);
  equalList(await reflectedPromise, [1, 2]);

  // Reflection trap exceptions retain 0.2.0 identity, including primitives.
  const trapCases = [
    ['listInt', [1], 'getOwnPropertyDescriptor'],
    ['mapInt', { a: 1 }, 'getPrototypeOf'],
    ['mapInt', { a: 1 }, 'ownKeys'],
    ['mapInt', { a: 1 }, 'getOwnPropertyDescriptor'],
  ];
  for (const [base, target, trap] of trapCases) {
    for (const reason of [new Error('proxy error'), new TypeError('proxy type'), new RangeError('proxy range'), 'primitive', 17, false, null, undefined]) {
      for (const suffix of ['', 'Async']) {
        const proxy = new Proxy(target, { [trap]() { throw reason; } });
        let caught = false;
        try { await invoke(`${base}${suffix}`, proxy); } catch (error) {
          caught = true;
          if (reason === null || reason === undefined) {
            assert(error instanceof Error);
            assert.match(error.message, /null|undefined/);
            assert.equal(typeof error.dartStack, 'string');
          } else {
            assert(Object.is(error, reason), `${base}/${trap} preserves thrown identity`);
          }
        }
        assert(caught, `${base}/${trap} must fail`);
        equalList(await invoke(`listInt${suffix}`, [42]), [42]);
      }
    }
  }

  // Diagnostic stack extraction must never replace the original JS reason.
  const replacementError = new Error('diagnostic getter replacement');
  const throwingStack = new Error('original throwing stack');
  Object.defineProperty(throwingStack, 'stack', { get() { throw replacementError; } });
  const hostileStackReasons = [throwingStack];
  for (const stack of [{ unexpected: true }, Symbol('non-string stack'), 17]) {
    const original = new Error('original non-string stack');
    Object.defineProperty(original, 'stack', { get() { return stack; } });
    hostileStackReasons.push(original);
  }
  hostileStackReasons.push(new Proxy(new Error('original proxied error'), {
    getPrototypeOf() { throw replacementError; },
  }));
  for (const [base, target, trap] of trapCases) {
    for (const original of hostileStackReasons) {
      for (const suffix of ['', 'Async']) {
        const input = new Proxy(target, { [trap]() { throw original; } });
        let caught = false;
        try { await invoke(`${base}${suffix}`, input); } catch (error) {
          caught = true;
          assert(Object.is(error, original), `${base}/${trap} stack extraction preserves original reason`);
        }
        assert(caught, `${base}/${trap} must fail with its original reason`);
        equalList(await invoke(`listInt${suffix}`, [42]), [42]);
      }
    }
  }

  // Equal warmup and measured workloads bound retained containers, not timing.
  async function batch() {
    const inputList = Array.from({ length: 4096 }, (_, i) => i);
    const inputMap = Object.fromEntries(inputList.map(i => [`k${i}`, i]));
    for (let start = 0; start < 256; start += 16) {
      const pending = [];
      for (let i = 0; i < 16; i++) {
        const list = invoke('listInt', inputList);
        const object = invoke('mapInt', inputMap);
        assert.equal(list[4095], 4095); assert.equal(object.k4095, 4095);
        pending.push(invoke('listIntAsync', inputList).then(result => assert.equal(result[4095], 4095)));
        pending.push(invoke('mapIntAsync', inputMap).then(result => assert.equal(result.k4095, 4095)));
        const byteInputs = [new Uint8Array(4096), new Uint8Array(4096)];
        assert.equal(invoke('listBytes', byteInputs)[1].length, 4096);
        pending.push(invoke('listBytesAsync', byteInputs).then(result => assert.equal(result[1].length, 4096)));
      }
      await Promise.all(pending);
    }
  }
  await batch();
  global.gc();
  const before = process.memoryUsage();
  await batch();
  await immediate();
  global.gc();
  const after = process.memoryUsage();
  const retained = { heapUsed: after.heapUsed - before.heapUsed, arrayBuffers: after.arrayBuffers - before.arrayBuffers };
  assert(retained.heapUsed < 16 * 1024 * 1024, `host heap retained ${retained.heapUsed}`);
  assert(retained.arrayBuffers < 16 * 1024 * 1024, `array buffers retained ${retained.arrayBuffers}`);
  for (const snapshot of snapshots) equalList(snapshot, [1, 2]);
  await immediate(); await immediate();
  assert.deepEqual(unhandled, [], 'failed conversions must not leak async errors');
  console.log(JSON.stringify({ checks, nativeFunctions: names.length, node: process.version, retained }));
} finally {
  process.removeListener('unhandledRejection', onUnhandled);
  process.removeListener('uncaughtException', onUnhandled);
}
