import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { add, calls, echo, fail } from './module.wasm';

const compiled = await WebAssembly.compile(readFileSync(new URL('./module.wasm', import.meta.url)), {builtins: ['js-string']});
const exports = WebAssembly.Module.exports(compiled);
for (const name of ['add', 'calls', 'echo', 'fail']) {
  assert.deepEqual(exports.find(e => e.name === name), {name, kind: 'function'});
}
const imports = WebAssembly.Module.imports(compiled);
assert(imports.some(e => e.module === './boundary.mjs' && e.name === 'readInt'));
assert(imports.some(e => e.module === './host.mjs'));
assert(imports.every(e => e.module.startsWith('./') || e.module === 'wasm:js-string'));
assert.equal(calls(), 0, 'import does not run Dart business main');
assert.equal(add(2, 3), 5);
assert.equal(calls(), 1);
assert.equal(add.length, 2);
assert.throws(() => new add(1, 2), TypeError);

let coercions = 0;
const hostile = {
  valueOf() { coercions++; throw Error('coerced'); },
  toString() { coercions++; throw Error('coerced'); },
  [Symbol.toPrimitive]() { coercions++; throw Error('coerced'); },
};
for (const wrong of ['2', true, false, null, undefined, 2n, Symbol('x'), [], {}, hostile]) {
  assert.throws(() => add(wrong, 1), TypeError);
  assert.throws(() => add(1, wrong), TypeError);
}
for (const wrong of [NaN, Infinity, -Infinity, 1.5, Number.MAX_SAFE_INTEGER + 1, Number.MIN_SAFE_INTEGER - 1]) {
  assert.throws(() => add(wrong, 0), RangeError);
  assert.throws(() => add(0, wrong), RangeError);
}
assert.throws(() => add(), TypeError);
assert.throws(() => add(1), TypeError);
assert.equal(coercions, 0);
assert.equal(calls(), 1, 'invalid arguments never entered business code');
for (const value of [0, 1, -1, Number.MAX_SAFE_INTEGER, Number.MIN_SAFE_INTEGER]) {
  assert.equal(echo(value), value);
}
assert.equal(echo(-0), 0, 'Dart int canonicalizes negative zero');
assert.throws(() => add(Number.MAX_SAFE_INTEGER, 1), RangeError);
assert.throws(() => add(Number.MIN_SAFE_INTEGER, -1), RangeError);
assert.throws(() => fail(1), e => e instanceof Error && !(e instanceof WebAssembly.Exception) && /intentional failure/.test(e.message));
assert.throws(() => fail(2), e => e instanceof Error && !(e instanceof WebAssembly.Exception) && /description unavailable/.test(e.message));
assert.equal(fail(0), 0);
assert.equal(add(3, 4), 7, 'errors do not poison runtime');
const [again, concurrent] = await Promise.all([import('./module.wasm'), import('./module.wasm')]);
assert.equal(again.add, add);
assert.equal(concurrent.add, add);
assert.equal(again.calls(), calls(), 'repeated imports retain same Dart state');
console.log('Generated scalar Wasm boundary: passed');

// A copied package is a separate URL graph, with separate Dart module state.
const { cpSync, mkdirSync } = await import('node:fs');
mkdirSync(new URL('./isolated/', import.meta.url));
for (const name of ['module.wasm', 'host.mjs', 'boundary.mjs']) {
  cpSync(new URL(name, import.meta.url), new URL('./isolated/' + name, import.meta.url));
}
const independent = await import('./isolated/module.wasm');
assert.notEqual(independent.add, add);
assert.equal(independent.calls(), 0);
assert.equal(independent.add(10, 20), 30);
assert.equal(independent.calls(), 1);
assert.notEqual(calls(), independent.calls());

// A missing host dependency is an import error, not a partially usable module.
mkdirSync(new URL('./missing-host/', import.meta.url));
cpSync(new URL('./module.wasm', import.meta.url), new URL('./missing-host/module.wasm', import.meta.url));
await assert.rejects(import('./missing-host/module.wasm'), e => e.code === 'ERR_MODULE_NOT_FOUND');
console.log('Module identity, isolation and import failure: passed');
