import {verifyArguments} from './argument_contract.mjs';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  argumentCalls, requiredNullable, optionalNumber, optionalNullable,
  optionalNull, optionalValues, optionalText, optionalDouble, optionalNaN,
  optionalInfinity, optionalNegativeInfinity, optionalWide, optionalBigInt,
  namedValues, requiredNamed, namedWide, manyNamed, optionalFailure,
  customListDefault, customMapDefault, customNestedDefault, customDefaultIdentity,
} from './module.wasm';

const compiled = await WebAssembly.compile(
  readFileSync(new URL('./module.wasm', import.meta.url)),
  {builtins: ['js-string']},
);
const exports = WebAssembly.Module.exports(compiled);
for (const name of ['argumentCalls', 'requiredNullable']) {
  assert.deepEqual(exports.find(e => e.name === name), {name, kind: 'function'});
}
const callables = {
  optionalNumber, optionalNullable, optionalNull, optionalValues, optionalText,
  optionalDouble, optionalNaN, optionalInfinity, optionalNegativeInfinity,
  optionalWide, optionalBigInt, namedValues, requiredNamed, namedWide,
  manyNamed, optionalFailure,
  customListDefault, customMapDefault, customNestedDefault, customDefaultIdentity,
};
for (const [name, value] of Object.entries(callables)) {
  assert.deepEqual(exports.find(e => e.name === name), {name, kind: 'global'});
  assert.equal(typeof value, 'function');
  assert.equal(value instanceof WebAssembly.Global, false);
}
verifyArguments({argumentCalls, requiredNullable, ...callables});
const again = await import('./module.wasm');
assert.equal(again.optionalNumber, optionalNumber);
assert.equal(again.namedValues, namedValues);
assert.equal(again.argumentCalls(), argumentCalls());
console.log('Generated optional and named scalar calls: passed');
