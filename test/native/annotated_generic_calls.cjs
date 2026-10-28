'use strict';

const assert = require('node:assert/strict');

module.exports = async function verifyGenericCalls(path) {
  const addon = require(path);
  const double = addon.doubleBox();
  assert.equal(addon.boxType(double), 'double');
  assert.equal(addon.writeBox(double, 2), 2);
  assert.equal(addon.numeric(double, 3), 3);
  assert.throws(() => addon.numeric(double, '3'), TypeError);

  const integer = addon.intBox();
  assert.equal(addon.boxType(integer), 'int');
  assert.throws(() => addon.exchange(double, integer), /Conflicting Dart types/);
  assert.throws(() => addon.exchange(integer, double), /Conflicting Dart types/);
  assert.equal(double.value, 3);
  assert.equal(integer.value, 1);
  const other = addon.doubleBox();
  addon.exchange(double, other);
  assert.equal(other.value, 3);
  assert.equal(double.value, 1);
  assert.equal(addon.dependent(other, double, 4), 4);

  const amount = addon.amountBox();
  assert.equal(addon.boxType(amount), 'Amount');
  assert.deepEqual(addon.writeBox(amount, {value: '42'}), {value: 42});
  assert.throws(() => addon.writeBox(amount, {value: 42}), TypeError);
  const reboxed = addon.rebox(amount, {value: '43'});
  assert.equal(addon.boxType(reboxed), 'Amount');
  assert.deepEqual(reboxed.value, {value: 43});
  reboxed.value = {value: '44'};
  assert.deepEqual(reboxed.value, {value: 44});

  const list = addon.listBox();
  const values = [3, 4];
  assert.deepEqual(addon.writeBox(list, values), values);
  values.push(5);
  assert.deepEqual(list.value, [3, 4]);
  assert.throws(() => addon.writeBox(list, [3.5]), RangeError);
  assert.deepEqual(list.value, [3, 4]);

  let reads = 0;
  assert.deepEqual(addon.namedBox({
    get box() { reads++; return amount; },
    value: {value: '45'},
  }), {value: 45});
  assert.equal(reads, 1);
  const pair = addon.pair();
  assert.deepEqual(addon.writePair(pair, 5, {value: '6'}), {value: 6});
  assert.equal(pair.key, 5);
  assert.deepEqual(pair.value, {value: 6});

  const service = addon.service();
  assert.equal(service.update(double, 7), 7);
  assert.equal(service.mode, 77);
  assert.equal(service.update(double, 8, {mode: 9}), 8);
  assert.equal(service.mode, 9);

  assert.deepEqual(addon.optionalBox({value: '9'}, amount), {value: 9});
  const raw = {value: 10};
  assert.equal(addon.optionalBox(raw), raw);
  assert.equal(addon.optionalBox(raw, null), raw);
  assert.throws(() => addon.optionalBox(raw, undefined), TypeError);
  assert.equal(addon.bounded(1), 'num');
  assert.equal(addon.bounded(1, double), 'double');
  assert.equal(addon.sameType(), 'dynamic');
  assert.equal(addon.sameType(null, double), 'double');
  assert.equal(addon.defaultBound(double), 'double/double');
  assert.equal(addon.defaultBound(double, double), 'double/double');
  assert.deepEqual(addon.defaultValue(amount, {value: '10'}), {value: 10});
  assert.deepEqual(addon.namedOptional({value: '10'}, {box: amount}), {value: 10});
  assert.equal(addon.namedOptional(raw), raw);
  assert.equal(addon.namedOptional(raw, {box: null}), raw);
  assert.equal(addon.optionalRebox(raw).value, raw);
  const optional = addon.optionalRebox({value: '11'}, amount);
  assert.equal(addon.boxType(optional), 'Amount');
  assert.deepEqual(optional.value, {value: 11});

  assert.deepEqual(addon.transform(amount, value => ({value: String(value.value + 1)})), {value: 10});
  assert.deepEqual(await addon.asynchronous(amount, Promise.resolve({value: '12'})), {value: 12});
  const future = addon.futureBox();
  assert.equal(await addon.asynchronous(future, Promise.resolve(13)), 13);
  await assert.rejects(addon.asynchronous(future, Promise.resolve('wrong')), TypeError);
  const futureAmount = addon.futureAmountBox();
  assert.deepEqual(await addon.asynchronous(futureAmount, Promise.resolve({value: '14'})), {value: 14});
  await assert.rejects(addon.asynchronous(futureAmount, Promise.resolve({value: 14})), TypeError);
  const nullableFuture = addon.nullableFutureBox();
  assert.equal(await addon.asynchronous(nullableFuture, Promise.resolve(null)), null);
  assert.equal(await addon.asynchronous(nullableFuture, Promise.resolve(15)), 15);
  assert.deepEqual(addon.collection(amount, [{value: '13'}]), [{value: 13}]);
  assert.throws(() => addon.collection(amount, [{value: 13}]), TypeError);

  const readout = addon.readoutBox();
  assert.deepEqual(addon.read(readout), [{value: 42}, null]);
  assert.deepEqual(addon.fromInput(readout, [null]), [null]);
  assert.deepEqual(addon.fromInput(readout, []), []);
  assert.throws(() => addon.fromInput(readout, [{value: 42}]), /no annotated input constructor/);

  const opaque = new addon.Box(raw);
  assert.equal(addon.boxType(opaque), 'dynamic');
  assert.equal(addon.writeBox(opaque, raw), raw);
  assert.equal(addon.rebox(opaque, raw).value, raw);
  assert.throws(() => addon.numeric(opaque, 1), TypeError);
  assert.throws(() => addon.writeBox({}, 1), TypeError);
};
