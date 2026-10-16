import assert from 'node:assert/strict';
import {optionalNumber, namedValues, requiredNamed} from '@napi/foundation-fixture';
import {optionalNumber as subpath} from '@napi/foundation-fixture/module.wasm';

assert.equal(optionalNumber, subpath);
assert.equal(optionalNumber(), 7);
assert.equal(optionalNumber(undefined), 7);
assert.equal(namedValues(0, {count: 0, flag: false, label: '', maybe: null}), '0|0|false||null');
assert.equal(requiredNamed(0, {value: null}), null);
assert.throws(() => requiredNamed(0, {value: undefined}), TypeError);
console.log('PASS: freshly installed argument package root and Wasm subpath');
