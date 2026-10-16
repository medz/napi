import assert from 'node:assert/strict';
import {
  structuralCalls, structuralLists, structuralSaved, structuralRecords,
  structuralNamed, structuralSingle, structuralEmpty, structuralBooleans,
  structuralDoubles, structuralStrings, structuralBigInts, structuralOptional,
  structuralUnsafeOutput, structuralLargeOutput,
  structuralDepth, structuralDeepOutput,
  structuralThrowingOutput,
} from './module.wasm';

function reject(operation, kind, path, message) {
  assert.throws(operation, (error) => error instanceof kind &&
    error.message.startsWith(path + ': ') && error.message.includes(message),
  `${kind.name} at ${path}: ${message}`);
}

assert.equal(structuralLists(null), null);
const source = [[1, null], null, []];
const result = structuralLists(source);
assert.deepEqual(result, source);
assert.notEqual(result, source);
assert.notEqual(result[0], source[0]);
source[0][0] = 9;
result[0][0] = 20;
assert.deepEqual(structuralSaved(), [[1, null], null, []]);
const saved = structuralSaved();
saved[0].push(100);
assert.deepEqual(structuralSaved(), [[1, null], null, []]);

const repeated = [4];
const duplicated = structuralLists([repeated, repeated]);
assert.notEqual(duplicated[0], duplicated[1]);
duplicated[0].push(5);
assert.deepEqual(duplicated[1], [4]);
assert.deepEqual(structuralLists([Object.assign([], {length: 0})]), [[]]);

const text = 'a\ud800b\udfffc\u0000\u2028\u2029';
const item = {$1: text, values: [2, null], detail: {flag: true, ratio: -0}};
assert.deepEqual(structuralRecords([item, null]), [item, null]);
const recordOutput = structuralRecords([item, item]);
assert.notEqual(recordOutput[0], recordOutput[1]);
assert.notEqual(recordOutput[0].values, item.values);
assert.notEqual(recordOutput[0].detail, item.detail);
recordOutput[0].detail.flag = false;
assert.equal(recordOutput[1].detail.flag, true);
assert.deepEqual(structuralNamed({values: [1, null], nested: {label: text}}),
  {values: [1, null], nested: {label: text}});
assert.equal(structuralNamed(null), null);
assert.deepEqual(structuralSingle({$1: 7}), {$1: 7});
assert.deepEqual(structuralEmpty({}), {});
assert.deepEqual(structuralBooleans([true, false]), [true, false]);
assert.deepEqual(structuralStrings([text]), [text]);
assert.deepEqual(structuralDoubles([NaN, Infinity, -Infinity, -0]), [NaN, Infinity, -Infinity, -0]);
const huge = 1n << 300n;
assert.deepEqual(structuralBigInts([{wide: 9223372036854775807n, huge}]),
  [{wide: 9223372036854775807n, huge}]);
assert.equal(structuralOptional(), null);
assert.equal(structuralOptional(undefined), null);
assert.equal(structuralOptional(null), null);
assert.deepEqual(structuralOptional([null, 1]), [null, 1]);

const calls = structuralCalls();
reject(() => structuralLists([[1], [2, 'wrong']]), TypeError,
  'structuralLists.value[1][1]', 'expected a JavaScript number or null');
assert.equal(structuralCalls(), calls, 'later-element failure must prevent business invocation');
reject(() => structuralLists(undefined), TypeError, 'structuralLists.value', 'expected an Array');
reject(() => structuralLists([[undefined]]), TypeError,
  'structuralLists.value[0][0]', 'expected a JavaScript number or null');
reject(() => structuralLists([[1.5]]), RangeError,
  'structuralLists.value[0][0]', 'safe integer');
reject(() => structuralLists([[9007199254740992]]), RangeError,
  'structuralLists.value[0][0]', 'safe integer');
reject(() => structuralBigInts([{wide: 9223372036854775808n, huge}]), RangeError,
  'structuralBigInts.value[0].wide', 'signed 64-bit');
reject(() => structuralBooleans([1]), TypeError, 'structuralBooleans.value[0]', 'boolean');
reject(() => structuralStrings([new String('x')]), TypeError, 'structuralStrings.value[0]', 'string');
reject(() => structuralDoubles(['1']), TypeError, 'structuralDoubles.value[0]', 'number');

const sparse = new Array(2);
sparse[0] = [1];
reject(() => structuralLists(sparse), TypeError, 'structuralLists.value[1]', 'own data property');
let gets = 0;
const getterList = [];
Object.defineProperty(getterList, '0', {get() { gets++; return [1]; }});
reject(() => structuralLists(getterList), TypeError,
  'structuralLists.value[0]', 'own data property');
const getterRecord = {$1: 'x', values: null};
Object.defineProperty(getterRecord, 'detail', {get() { gets++; return null; }});
reject(() => structuralRecords([getterRecord]), TypeError,
  'structuralRecords.value[0].detail', 'own data property');
assert.equal(gets, 0, 'conversion must never invoke accessors');
for (const prototype of [Array.prototype, Object.prototype]) {
  const previous = Object.getOwnPropertyDescriptor(prototype, '0');
  let setters = 0;
  let failure;
  let listOutput;
  let recordOutput;
  Object.defineProperty(prototype, '0', {
    configurable: true,
    set() { setters++; throw new Error('inherited index setter invoked'); },
  });
  try {
    listOutput = structuralLists([[1]]);
    recordOutput = structuralSingle({$1: 1});
  } catch (error) {
    failure = error;
  } finally {
    if (previous) Object.defineProperty(prototype, '0', previous);
    else delete prototype['0'];
  }
  assert.equal(setters, 0, 'structural snapshots must create own data properties');
  assert.equal(failure, undefined);
  assert.deepEqual(listOutput, [[1]]);
  assert.deepEqual(recordOutput, {$1: 1});
}
const inherited = Object.create({values: null});
inherited.$1 = 'x';
inherited.detail = null;
reject(() => structuralRecords([inherited]), TypeError,
  'structuralRecords.value[0]', 'plain record');
const missing = {$1: 'x', values: null};
reject(() => structuralRecords([missing]), TypeError,
  'structuralRecords.value[0].detail', 'own data property');
reject(() => structuralRecords([{$1: 'x', values: null, detail: null, extra: 1}]),
  TypeError, 'structuralRecords.value[0].extra', 'unknown record field');
const extraArray = [[1]];
extraArray.extra = 2;
reject(() => structuralLists(extraArray), TypeError,
  'structuralLists.value.extra', 'unknown Array property');
const symbolArray = [];
symbolArray[Symbol('extra')] = 1;
reject(() => structuralLists(symbolArray), TypeError,
  'structuralLists.value.Symbol(extra)', 'unknown Array property');
const cycle = [];
cycle.push(cycle);
reject(() => structuralLists(cycle), TypeError,
  'structuralLists.value[0]', 'cyclic structural value');
reject(() => structuralLists([Array(10000).fill(1)]), RangeError,
  'structuralLists.value[0]', 'work limit (10000)');
reject(() => structuralUnsafeOutput(), RangeError,
  'structuralUnsafeOutput result[0]', 'safe integer');
reject(() => structuralLargeOutput(), RangeError,
  'structuralLargeOutput result', 'work limit (10000)');
let deep = 1;
for (let i = 0; i < 65; i++) deep = [deep];
reject(() => structuralDepth(deep), RangeError,
  'structuralDepth.value' + '[0]'.repeat(64), 'depth limit (64)');
reject(() => structuralDeepOutput(), RangeError,
  'structuralDeepOutput result' + '[0]'.repeat(64), 'depth limit (64)');
let allowedDepth = [];
for (let i = 0; i < 63; i++) allowedDepth = [allowedDepth];
assert.deepEqual(structuralDepth(allowedDepth), allowedDepth);
assert.deepEqual(structuralLists([Array(9998).fill(1)]), [Array(9998).fill(1)]);
assert.throws(() => structuralThrowingOutput(false), (error) =>
  error instanceof Error && error.message.includes('output length failed'));
assert.throws(() => structuralThrowingOutput(true), (error) =>
  error instanceof Error && error.message.includes('output element failed'));
assert.deepEqual(structuralLists([[7]]), [[7]], 'failure must not poison the next call');
console.log('Generated structural Wasm conformance passed');
