import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import * as annotated from '@napi/void-fixture';
import * as external from '@napi/void-external';

for (const [name, api] of [['fixture', annotated], ['external', external]]) {
  let calls = 0;
  let value = null;
  let label = '';
  const check = () => assert.equal(api.check(calls, value, label), undefined);
  const invoke = (call, nextValue, nextLabel = label) => {
    assert.equal(call(), undefined);
    calls++; value = nextValue; label = nextLabel; check();
  };
  assert.equal(api.empty(), undefined);
  assert.equal(api.empty.length, 0);
  assert.equal(api.requiredValue.length, 1);
  check();
  invoke(() => api.requiredValue(3), 3);
  invoke(() => api.numbers([1, 2]), 3);
  invoke(() => api.optionalValue(), 7);
  invoke(() => api.optionalValue(undefined), 7);
  invoke(() => api.optionalValue(0), 0);
  invoke(() => api.namedValue(), 11, 'default');
  invoke(() => api.namedValue(undefined), 11, 'default');
  invoke(() => api.namedValue({value: undefined, label: undefined}), 11, 'default');
  invoke(() => api.namedValue({value: 4, label: '雪\ud800'}), 4, '雪\ud800');
  invoke(() => api.requiredNamed({value: null}), null);
  invoke(() => api.requiredNamed({value: 8}), 8);
  for (const invalid of [
    () => api.requiredValue(), () => api.requiredValue(undefined),
    () => api.numbers([1, 'bad']), () => api.numbers(null),
    () => api.requiredValue(null), () => api.requiredValue('3'),
    () => api.optionalValue(null), () => api.namedValue(null),
    () => api.namedValue({value: '3'}), () => api.namedValue({extra: 1}),
    () => api.requiredNamed(), () => api.requiredNamed({}),
    () => api.requiredNamed({value: undefined}), () => api.fail('wrong'),
  ]) {
    assert.throws(invalid, TypeError); check();
  }
  let getterCalls = 0;
  assert.throws(() => api.namedValue({get value() {getterCalls++; return 1;}}), TypeError);
  assert.equal(getterCalls, 0); check();
  assert.throws(() => api.requiredValue(1.5), RangeError); check();
  assert.throws(() => api.requiredValue(2 ** 53), RangeError); check();
  assert.throws(() => api.fail(19), /void-business-error/);
  calls++; value = 19; check();
  assert.throws(() => api.fail(), /void-business-error/);
  calls++; value = 0; check();
  assert.equal(api.empty(), undefined); check();
  // Fixed-arity void exports remain native Wasm functions in a mixed facade.
  const url = import.meta.resolve(`@napi/void-${name}`);
  if (url.endsWith('.wasm')) {
    const module = new WebAssembly.Module(readFileSync(new URL(url)));
    const exports = WebAssembly.Module.exports(module);
    assert.equal(exports.find(entry => entry.name === 'empty').kind, 'function');
    assert.equal(exports.find(entry => entry.name === 'requiredValue').kind, 'function');
    assert.equal(exports.find(entry => entry.name === 'optionalValue').kind, 'global');
  }
}
console.log('Void-only annotated/external fresh packages: passed');
