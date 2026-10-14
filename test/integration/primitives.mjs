// Real Dart Wasm ESM contract checks, executed in both Node and Bun.
import assert from 'node:assert/strict';
import * as bindings from '@napi/foundation-fixture';
import { add, echoInt, echoDouble, negate, echoString, accept, unsafeOutput, fail, api, $echo, failBadMessage, failBadType, failArgumentMessage, unsafeConditionalOutput, echoConditional } from '@napi/foundation-fixture';

const [firstImport, secondImport] = await Promise.all([
  import('@napi/foundation-fixture'), import('@napi/foundation-fixture'),
]);
assert.equal(firstImport, secondImport);
assert.equal(firstImport, bindings);
assert.equal((await import('@napi/foundation-fixture')).add, add);
assert.equal(add(20, 22), 42);
assert.equal(api(7), 7);
assert.ok(Object.is(echoInt(-0), 0)); // Dart int canonicalizes negative zero.
assert.equal($echo(9), 9);
for (const value of [0, -1, 1, Number.MAX_SAFE_INTEGER, Number.MIN_SAFE_INTEGER]) {
  assert.equal(echoInt(value), value);
}
for (const value of [1.5, NaN, Infinity, -Infinity, Number.MAX_SAFE_INTEGER + 1]) {
  assert.throws(() => echoInt(value), RangeError);
}
for (const value of [null, undefined, '1', true, 1n, {}, []]) {
  assert.throws(() => echoInt(value), TypeError);
}
assert.throws(() => add(1), TypeError);
assert.throws(() => unsafeOutput(), RangeError);
assert.throws(() => add(Number.MAX_SAFE_INTEGER, 1), RangeError);
for (const value of [0, -0, 1.25, NaN, Infinity, -Infinity]) {
  assert.ok(Object.is(echoDouble(value), value));
}
assert.throws(() => echoDouble('1'), TypeError);
assert.equal(negate(true), false);
assert.equal(negate(false), true);
assert.throws(() => negate(1), TypeError);
for (const value of ['', 'hello', 'é\u0000𐐀', '\ud800', '\udfff', 'a\ud800b']) {
  assert.equal(echoString(value), value);
}
assert.throws(() => echoString(null), TypeError);
assert.equal(accept('ok'), undefined);
for (const [kind, ErrorClass, dartType] of [
  ['range', RangeError, 'RangeError'],
  ['type', TypeError, 'ArgumentError'],
  ['state', Error, 'StateError'],
]) {
  assert.throws(() => fail(kind), error => {
    assert.ok(error instanceof ErrorClass);
    assert.equal(error.dartType, dartType);
    assert.ok(error.message.includes('fixture'));
    assert.equal(typeof error.dartStack, 'string');
    assert.ok(error.dartStack.length > 0);
    return true;
  });
}
assert.equal(Object.getOwnPropertyNames(globalThis).filter(k => k.startsWith('__napi_bootstrap_')).length, 0);
console.log('Real Wasm primitive contracts passed.');

for (const [invoke, ErrorClass, expectedType, expectedMessage] of [
  [failBadMessage, Error, '_BadMessage', 'Dart exception (message unavailable)'],
  [failBadType, Error, 'UnknownDartError', 'fixture opaque exception'],
  [failArgumentMessage, TypeError, 'ArgumentError', "Invalid argument (value): Instance of '_BadMessage'"],
]) {
  assert.throws(invoke, error => {
    assert.ok(error instanceof ErrorClass);
    assert.equal(error.dartType, expectedType);
    assert.equal(error.message, expectedMessage);
    assert.equal(typeof error.dartStack, 'string');
    return true;
  });
}
console.log('Throwing diagnostic formatting remains a JavaScript Error.');

assert.throws(unsafeConditionalOutput, RangeError);
assert.throws(() => echoConditional(Number.MAX_SAFE_INTEGER + 1), RangeError);
assert.throws(() => echoConditional(1.5), RangeError);
assert.equal(echoConditional(Number.MAX_SAFE_INTEGER), Number.MAX_SAFE_INTEGER);
console.log('Conditional Wasm type policies preserve safe-number checks.');
