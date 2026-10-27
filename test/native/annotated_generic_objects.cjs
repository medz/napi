'use strict';

const assert = require('node:assert/strict');

module.exports = async function verifyAnnotatedGenericObjects(path) {
  const addon = require(path);
  const input = { value: 7 };
  const integer = addon.echoInt(input);
  assert.notEqual(integer, input);
  assert.deepEqual(integer, {
    value: 7, optional: null, note: 'kept', intType: true, stringType: false, isDoubleType: false,
  });
  assert.deepEqual(addon.echoText({ value: 'hello', optional: 'next', note: 'custom' }), {
    value: 'hello', optional: 'next', note: 'custom', intType: false, stringType: true, isDoubleType: false,
  });
  const double = addon.echoDouble({ value: 3 });
  assert.equal(double.value, 3);
  assert.equal(double.isDoubleType, true);
  integer.value = 9;
  assert.equal(input.value, 7);
  assert.equal(addon.nullable(), null);
  assert.equal(addon.nullable(null), null);
  assert.equal(addon.nullable({ value: 2 }).intType, true);
  const object = { token: 1 };
  assert.equal(addon.echo({ value: object }).value, object);
  assert.equal(addon.echo({ value: 3 }).value, 3);
  assert.deepEqual(addon.echoPoint({ value: { value: '3' }, optional: { value: '4' } }), {
    value: { value: 3 }, optional: { value: 4 }, note: 'kept', intType: false, stringType: false, isDoubleType: false,
  });
  const bounced = addon.bounce(value => {
    assert.equal(value.value.value, 3);
    return { value: { value: String(value.value.value + 1) } };
  });
  assert.equal(bounced({ value: { value: '3' } }).value.value, 4);
  assert.throws(() => addon.bounce(value => value)({ value: { value: '3' } }), TypeError);
  const grouped = await addon.groups(Promise.resolve({
    one: [{ value: { value: '5' } }, null],
  }));
  assert.equal(grouped.one[0].value.value, 5);
  assert.equal(grouped.one[1], null);
  await assert.rejects(addon.groups(Promise.resolve({
    one: [{ value: { value: 5 } }],
  })), TypeError);
  assert.deepEqual(addon.readout(), { value: 7 });
  assert.deepEqual(addon.nestedReadout(), { value: { value: 7 } });
  const intFactory = () => 7;
  assert.equal(addon.echoIntProducer({ create: intFactory }).create, intFactory);
  const pointFactory = () => ({ value: '9' });
  const pointProducer = addon.echoPointProducer({ create: pointFactory });
  assert.notEqual(pointProducer.create, pointFactory);
  assert.deepEqual(pointProducer.create(), { value: 9 });
  assert.equal(addon.Envelope, undefined);
  assert.equal(addon.Readout, undefined);

  const recursive = { value: 1, next: { value: [2], next: { value: [[3]] } } };
  const copied = addon.echoRecursive(recursive);
  assert.deepEqual(copied, {
    value: 1, next: { value: [2], next: { value: [[3]], next: null } },
  });
  assert.notEqual(copied.next.value, recursive.next.value);
  assert.throws(() => addon.echoRecursive({ value: 1, next: { value: ['wrong'] } }), TypeError);
  for (const invalid of [
    { value: '7' }, {}, { value: 7, optional: undefined }, { value: 7, note: undefined },
  ]) {
    assert.throws(() => addon.echoInt(invalid), TypeError);
  }
  assert.throws(() => addon.echoInt({ value: 1.5 }), RangeError);
  assert.throws(() => addon.echoText({ value: 7 }), TypeError);
  assert.throws(() => addon.echoPoint({ value: { value: 3 } }), TypeError);
  assert.throws(() => addon.nullable(undefined), TypeError);
};
