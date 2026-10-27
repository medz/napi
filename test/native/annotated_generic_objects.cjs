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
  const numberRun = value => value + 1;
  const numberHandler = addon.echoIntHandler({ run: numberRun });
  assert.equal(numberHandler.run, numberRun);
  assert.equal(numberHandler.run(3), 4);
  const amountRun = value => {
    assert.equal(typeof value.value, 'number');
    return { value: String(value.value + 2) };
  };
  const handler = addon.echoAmountHandler({ run: amountRun });
  assert.notEqual(handler.run, amountRun);
  const amount = handler.run({ value: '3' });
  assert.deepEqual(amount, { value: 5 });
  assert.deepEqual(Object.getOwnPropertySymbols(amount), []);
  assert.deepEqual(Object.keys(handler), ['run']);
  assert.deepEqual(addon.nativeHandler().run({ value: '3' }), { value: 4 });
  assert.deepEqual(addon.nativeListHandler().run([{ value: '3' }]), [{ value: 3 }]);
  assert.deepEqual(addon.nativeMapHandler().run({ one: { value: '4' } }), { one: { value: 4 } });
  const functionHandler = addon.nativeFunctionHandler();
  const functionResult = functionHandler.run(amount => {
    assert.equal(typeof amount.value, 'number');
    return { value: String(amount.value + 1) };
  });
  assert.deepEqual(functionResult({ value: '5' }), { value: 6 });
  assert.deepEqual(await addon.nativeFutureHandler().run(Promise.resolve({ value: '7' })), { value: 7 });
  const fnHolder = addon.echoFnHolder({ run: value => value });
  assert.equal(fnHolder.run('hello'), 'hello');
  assert.equal(addon.applyFnHolder(fnHolder, 7), 7);
  assert.equal(addon.scalarBound({ run: value => value }), true);
  assert.throws(() => addon.scalarBound({ run: () => 'wrong' }), TypeError);
  assert.deepEqual(addon.nativeStringHandler().run({ value: '7' }), { value: '7' });
  assert.throws(() => addon.nativeStringHandler().run({ value: 7 }), TypeError);
  assert.equal(await addon.nativeThenableHandler().run(Promise.resolve({ value: '7' })), 7);
  assert.deepEqual(addon.applyAmount({ value: '4' }, {
    run: value => ({ value: String(value.value + 1) }),
  }), { value: 5 });
  const nestedHandler = addon.nestedHandler({ value: { run: amountRun } });
  assert.deepEqual(nestedHandler.value.run({ value: '6' }), { value: 8 });
  const erasedRun = value => value;
  const erased = addon.echoHandler({ run: erasedRun });
  const erasedValue = { value: '7' };
  assert.equal(erased.run, erasedRun);
  assert.equal(erased.run(erasedValue), erasedValue);
  assert.equal(addon.echo({ value: erasedValue }).value.value, '7');
  assert.throws(() => handler.run({ value: 3 }), TypeError);
  assert.throws(() => functionResult({ value: 5 }), TypeError);
  assert.throws(() => addon.echoAmountHandler({ run: value => value }).run({ value: '3' }), TypeError);
  assert.equal(addon.Envelope, undefined);
  assert.equal(addon.Readout, undefined);
  assert.equal(addon.Handler, undefined);
  assert.equal(addon.Amount, undefined);

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
