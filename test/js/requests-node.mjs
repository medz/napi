import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import * as api from '@napi/requests';
import { summarize as subpath } from '@napi/requests/module.wasm';
import { summarize as relative } from './dist/module.wasm';

assert.equal(typeof api.summarize, 'function');
assert.equal(api.summarize, subpath);
assert.equal(api.summarize, relative);
assert.match(Function.prototype.toString.call(api.summarize), /\[native code\]/);
assert.equal(Object.hasOwn(api, 'Observation'), false);
assert.equal(Object.hasOwn(api, 'Summary'), false);
let checks = 0;
let cliChecks = 0;
function summarize(observations) {
  checks++;
  return api.summarize(observations);
}
function equalSummary(actual, expected) {
  assert(Array.isArray(actual));
  assert.deepEqual(actual.map(row => ({ ...row })), expected);
  for (const row of actual) assert.equal(Object.getPrototypeOf(row), null);
}
function failure(observations, type, message) {
  assert.throws(() => summarize(observations), error => error instanceof type && error.message === message);
}
function cli(input) {
  cliChecks++;
  const result = spawnSync(process.execPath, ['--disable-warning=ExperimentalWarning', fileURLToPath(new URL('./main.mjs', import.meta.url))], {
    input, encoding: 'utf8', timeout: 10000,
  });
  assert.ifError(result.error);
  assert.equal(result.signal, null);
  return result;
}
function cliSuccess(input, expected) {
  const result = cli(input);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stderr, '');
  assert.equal(result.stdout.indexOf('\n'), result.stdout.length - 1, 'CLI writes one JSON line');
  assert.deepEqual(JSON.parse(result.stdout), expected);
}
function cliFailure(input, message) {
  const result = cli(input);
  assert.equal(result.status, 1);
  assert.equal(result.stdout, '', 'failed ingestion or business validation must publish no partial summary');
  assert.equal(result.stderr, `${message}\n`);
}

const sampleText = readFileSync(new URL('./input.ndjson', import.meta.url), 'utf8');
const sample = sampleText.trim().split('\n').map(line => JSON.parse(line));
const sampleExpected = [
  { operation: 'GET /articles', calls: 2, failed: 1, totalDurationUs: 1000 },
  { operation: 'GET /status', calls: 1, failed: 0, totalDurationUs: 50 },
  { operation: 'POST /login', calls: 2, failed: 1, totalDurationUs: 1600 },
];
const output = summarize(sample);
equalSummary(output, sampleExpected);
assert.notEqual(output, sample);
assert.notEqual(output[0], sample[0]);
output[0].operation = 'mutated output';
output[0].calls = 99;
output.push(output[0]);
assert.equal(sample[0].operation, 'GET /articles');
assert.equal(sample.length, 5);
equalSummary(summarize(sample), sampleExpected);
const repeated = summarize(sample);
assert.notEqual(repeated[0], output[0]);
sample[0].operation = 'mutated input';
sample[0].durationUs = 0;
equalSummary(repeated, sampleExpected);
const empty = [];
const emptyOutput = summarize(empty);
assert.deepEqual(emptyOutput, []);
assert.notEqual(emptyOutput, empty);
assert.notEqual(summarize([]), emptyOutput);
const frozenSample = Object.freeze(sampleText.trim().split('\n').map(line => Object.freeze(JSON.parse(line))));
const frozenSnapshot = frozenSample.map(row => ({ ...row }));
const frozenOutput = summarize(frozenSample);
equalSummary(frozenOutput, sampleExpected);
assert.notEqual(frozenOutput, frozenSample);
assert.notEqual(frozenOutput[0], frozenSample[0]);
assert.equal(Object.isFrozen(frozenOutput), false);
assert.equal(Object.isFrozen(frozenOutput[0]), false);
frozenOutput[0].totalDurationUs = 0;
frozenOutput.push(frozenOutput[0]);
assert.deepEqual(frozenSample, frozenSnapshot);

const unicode = [
  { operation: 'read', durationUs: 3, success: true },
  { operation: 'Read', durationUs: 2, success: false },
  { operation: ' read ', durationUs: 4, success: true },
  { operation: '', durationUs: 0, success: true },
  { operation: 'e\u0301', durationUs: 6, success: true },
  { operation: 'é', durationUs: 7, success: false },
  { operation: '\ue000', durationUs: 10, success: true },
  { operation: '🚀', durationUs: 9, success: true },
  { operation: '\ud800', durationUs: 8, success: false },
  { operation: 'read', durationUs: 5, success: false },
];
const unicodeExpected = [
  { operation: '', calls: 1, failed: 0, totalDurationUs: 0 },
  { operation: ' read ', calls: 1, failed: 0, totalDurationUs: 4 },
  { operation: 'Read', calls: 1, failed: 1, totalDurationUs: 2 },
  { operation: 'e\u0301', calls: 1, failed: 0, totalDurationUs: 6 },
  { operation: 'read', calls: 2, failed: 1, totalDurationUs: 8 },
  { operation: 'é', calls: 1, failed: 1, totalDurationUs: 7 },
  { operation: '\ud800', calls: 1, failed: 1, totalDurationUs: 8 },
  { operation: '🚀', calls: 1, failed: 0, totalDurationUs: 9 },
  { operation: '\ue000', calls: 1, failed: 0, totalDurationUs: 10 },
];
equalSummary(summarize(unicode), unicodeExpected);
const specialNames = ['then', '__proto__', 'constructor'];
equalSummary(summarize(specialNames.map(operation => ({ operation, durationUs: 1, success: false }))), [
  { operation: '__proto__', calls: 1, failed: 1, totalDurationUs: 1 },
  { operation: 'constructor', calls: 1, failed: 1, totalDurationUs: 1 },
  { operation: 'then', calls: 1, failed: 1, totalDurationUs: 1 },
]);
const max = Number.MAX_SAFE_INTEGER;
equalSummary(summarize([
  { operation: 'safe', durationUs: max, success: true },
  { operation: 'safe', durationUs: 0, success: false },
  { operation: 'other', durationUs: max, success: true },
]), [
  { operation: 'other', calls: 1, failed: 0, totalDurationUs: max },
  { operation: 'safe', calls: 2, failed: 1, totalDurationUs: max },
]);
const valid = { operation: 'valid', durationUs: 1, success: true };
const negative = [valid, { ...valid, durationUs: -1 }];
const unsafe = [valid, { ...valid, durationUs: max + 1 }];
const overflow = [{ ...valid, durationUs: max }, valid];
const negativeMessage = 'RangeError: durationUs must be nonnegative';
const unsafeMessage = 'RangeError: parameter observations[1]["durationUs"]: Integer must be within the JavaScript safe integer range';
const overflowMessage = 'RangeError: totalDurationUs must be within the JavaScript safe integer range';
failure(negative, RangeError, negativeMessage);
failure(unsafe, RangeError, unsafeMessage);
failure(overflow, RangeError, overflowMessage);
failure([valid, { ...valid, operation: 1 }], TypeError, 'parameter observations[1]["operation"]: Expected a string');
failure([valid, { ...valid, success: 1 }], TypeError, 'parameter observations[1]["success"]: Expected a boolean');
failure([valid, { ...valid, durationUs: 0.5 }], TypeError, 'parameter observations[1]["durationUs"]: Expected an integer');
failure([valid, { operation: 'missing', durationUs: 1 }], TypeError, 'parameter observations[1]["success"]: Expected an own data property');
failure(null, TypeError, 'parameter observations: Expected an Array');
equalSummary(summarize([valid]), [{ operation: 'valid', calls: 1, failed: 0, totalDurationUs: 1 }]);

const ndjson = rows => rows.map(row => JSON.stringify(row)).join('\n');
cliSuccess(sampleText, sampleExpected);
cliSuccess('', []);
cliSuccess(`\r\n \t\r\n${sampleText.trim().replaceAll('\n', '\r\n')}\r\n\r\n`, sampleExpected);
cliSuccess(ndjson(unicode), unicodeExpected);
const malformed = cli(`${JSON.stringify(valid)}\n\n{bad\n`);
assert.equal(malformed.status, 1);
assert.equal(malformed.stdout, '');
assert.match(malformed.stderr, /^Invalid JSON on line 3: /);
cliFailure(ndjson(negative), negativeMessage);
cliFailure(ndjson(unsafe), unsafeMessage);
cliFailure(ndjson(overflow), overflowMessage);
cliFailure('null\n', 'parameter observations[0]: Expected an ordinary object');
cliFailure(ndjson([valid, { ...valid, success: 'true' }]), 'parameter observations[1]["success"]: Expected a boolean');
console.log(JSON.stringify({ checks, cliChecks, nativeFunctions: 1, node: process.version }));
