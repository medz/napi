import {verifyScalars} from './scalar_contract.mjs';
import assert from 'node:assert/strict';
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import {fileURLToPath, pathToFileURL} from 'node:url';
import {
  add, calls, scalarCalls, echo, fail, evaluate, argumentCount,
  echoBool, negate, echoString, reverseString, stringLength, stringCodeUnitAt,
  echoDouble, reciprocal, echoBigInt, addBigInt,
  nullableBool, nullableString, nullableDouble, nullableInt, nullableBigInt,
  echoWideInt, addWideInt, nullableWideInt, chooseWideInt, promoteWideInt,
  wideIntToDouble, unsafeIntResult, unsafeNullableIntResult,
} from './module.wasm';

const compiled = await WebAssembly.compile(readFileSync(new URL('./module.wasm', import.meta.url)), {builtins: ['js-string']});
const exports = WebAssembly.Module.exports(compiled);
const scalarExports = {
  add, calls, scalarCalls, echo, fail, evaluate, argumentCount,
  echoBool, negate, echoString, reverseString, stringLength, stringCodeUnitAt,
  echoDouble, reciprocal, echoBigInt, addBigInt,
  nullableBool, nullableString, nullableDouble, nullableInt, nullableBigInt,
  echoWideInt, addWideInt, nullableWideInt, chooseWideInt, promoteWideInt,
  wideIntToDouble, unsafeIntResult, unsafeNullableIntResult,
};
for (const name of Object.keys(scalarExports)) {
  assert.deepEqual(exports.find(e => e.name === name), {name, kind: 'function'});
}
const imports = WebAssembly.Module.imports(compiled);
assert(imports.some(e => e.module === './boundary.mjs' && e.name === 'readValue'));
assert(imports.some(e => e.module === './host.mjs'));
assert(imports.every(e => e.module.startsWith('./') || e.module === 'wasm:js-string'));
assert(!exports.some(e => e.name === 'eval' || e.name === 'arguments'));
verifyScalars(scalarExports);
const huge = (1n << 521n) + (1n << 257n) + 123456789n;
const [again, concurrent] = await Promise.all([import('./module.wasm'), import('./module.wasm')]);
assert.equal(again.add, add);
assert.equal(concurrent.add, add);
assert.equal(again.calls(), calls(), 'repeated imports retain same Dart state');
assert.equal(again.scalarCalls(), scalarCalls());
console.log('Generated scalar Wasm boundary: passed');

const temporary = mkdtempSync(fileURLToPath(new URL('./copies-', import.meta.url)));
const copies = pathToFileURL(`${temporary}/`);
try {
  // A copied package is a separate URL graph, with separate Dart module state.
  mkdirSync(new URL('./isolated/', copies));
  for (const name of ['module.wasm', 'host.mjs', 'boundary.mjs']) {
    cpSync(new URL(name, import.meta.url), new URL('./isolated/' + name, copies));
  }
  const independent = await import(new URL('./isolated/module.wasm', copies));
  assert.notEqual(independent.add, add);
  assert.equal(independent.calls(), 0);
  assert.equal(independent.scalarCalls(), 0);
  assert.equal(independent.add(10, 20), 30);
  assert.equal(independent.calls(), 1);
  assert.equal(independent.echoBigInt(huge), huge);
  assert.equal(independent.scalarCalls(), 1);
  assert.notEqual(calls(), independent.calls());
  assert.notEqual(scalarCalls(), independent.scalarCalls());

  // A missing host dependency is an import error, not a partially usable module.
  mkdirSync(new URL('./missing-host/', copies));
  cpSync(new URL('./module.wasm', import.meta.url), new URL('./missing-host/module.wasm', copies));
  await assert.rejects(import(new URL('./missing-host/module.wasm', copies)), e => e.code === 'ERR_MODULE_NOT_FOUND');
  console.log('Module identity, isolation and import failure: passed');
} finally {
  rmSync(temporary, {recursive: true, force: true});
}
