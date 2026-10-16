import assert from 'node:assert/strict';
import {structuralLists, structuralRecords, structuralSaved} from '@napi/foundation-fixture';
import {structuralLists as subpath} from '@napi/foundation-fixture/module.wasm';

assert.equal(structuralLists, subpath);
const input = [[1, null], null];
const output = structuralLists(input);
output[0][0] = 2;
input[0][0] = 3;
assert.deepEqual(structuralSaved(), [[1, null], null]);
assert.deepEqual(structuralRecords([{$1: 'x', values: null, detail: null}]),
  [{$1: 'x', values: null, detail: null}]);
assert.throws(() => structuralLists([[undefined]]), TypeError);
assert.deepEqual(subpath([[1]]), [[1]]);
console.log('PASS: freshly installed structural package root and Wasm subpath');
