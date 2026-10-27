'use strict';

const assert = require('node:assert/strict');
const { runInNewContext } = require('node:vm');

module.exports = function verifyAnnotatedDates(path) {
  const addon = require(path);
  const milliseconds = 1700000000123;
  const input = new Date(milliseconds);
  const result = addon.echoDate(input);
  assert(result instanceof Date);
  assert.notEqual(result, input);
  assert.equal(result.getTime(), milliseconds);
  assert.equal(addon.dateIsUtc(input), true);
  input.setTime(0);
  assert.equal(result.getTime(), milliseconds);
  assert.equal(addon.fromMicroseconds(-1).getTime(), -1);
  assert.equal(addon.fromMicroseconds(1).getTime(), 0);
  assert.throws(() => addon.echoDate(new Date(NaN)), RangeError);
  for (const invalid of [0, '2026-10-29', {}, { getTime() { return 0; } }, null, undefined]) {
    assert.throws(() => addon.echoDate(invalid), TypeError);
  }
  const foreign = runInNewContext(`new (class extends Date {
    getTime() { throw new Error('Date method must not be called'); }
  })(${milliseconds})`);
  assert.equal(addon.echoDate(foreign).getTime(), milliseconds);
  assert.equal(addon.dateIsUtc(foreign), true);
  assert.equal(addon.nullableDate(), null);
  assert.equal(addon.nullableDate(null), null);
  assert.equal(addon.nullableDate(result).getTime(), milliseconds);
  assert.throws(() => addon.nullableDate(undefined), TypeError);
  const values = [result, null];
  const copied = addon.echoDates(values);
  assert.notEqual(copied, values);
  assert.notEqual(copied[0], result);
  assert.equal(copied[0].getTime(), milliseconds);
  assert.equal(copied[1], null);
  let callbackInput;
  const bounced = addon.bounceDate(value => { callbackInput = value; return value; });
  const adapted = bounced(result);
  assert.notEqual(callbackInput, result);
  assert.notEqual(adapted, callbackInput);
  assert.equal(adapted.getTime(), milliseconds);
};
