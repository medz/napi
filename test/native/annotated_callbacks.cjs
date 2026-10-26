'use strict';

const assert = require('node:assert/strict');
const nextTurn = () => new Promise(resolve => setImmediate(resolve));

module.exports = async function verifyAnnotatedCallbacks(path) {
  const addon = require(path);
  assert.equal(addon.apply(4, value => value + 3), 7);
  const twice = addon.multiply(2);
  assert.equal(twice(7), 14);
  assert.equal(addon.echoCallback(twice), twice);
  assert.equal(addon.sharedCallback(), addon.sharedCallback());
  const zero = addon.zeroView();
  const optional = addon.optionalView();
  assert.notEqual(zero, optional);
  assert.equal(zero(), 1);
  assert.equal(zero(2), 1);
  assert.equal(optional(), 1);
  assert.equal(optional(2), 2);
  assert.throws(() => optional(undefined), TypeError);
  assert.equal(addon.zeroView(), zero);
  assert.equal(addon.optionalView(), optional);
  const reverseOptional = addon.reverseOptionalView();
  const reverseZero = addon.reverseZeroView();
  assert.notEqual(reverseZero, reverseOptional);
  assert.equal(reverseOptional(), 2);
  assert.equal(reverseOptional(2), 3);
  assert.equal(reverseZero(), 2);
  assert.equal(reverseZero(9), 2);
  assert.equal(addon.reverseOptionalView(), reverseOptional);
  assert.equal(addon.reverseZeroView(), reverseZero);
  const original = value => value + 10;
  assert.equal(addon.echoCallback(original), original);
  assert.equal(addon.nullableCallback(original), original);
  assert.equal(addon.nullableCallback(), null);
  assert.equal(addon.nullableCallback(null), null);
  assert.equal(addon.withDefault(4), 5);
  assert.equal(addon.withDefault(4, original), 14);
  for (const value of [null, undefined, {}, 1]) {
    assert.throws(() => addon.apply(4, value), TypeError);
  }
  assert.throws(() => addon.nullableCallback(undefined), TypeError);
  assert.throws(() => addon.withDefault(4, undefined), TypeError);
  assert.throws(() => addon.apply(4, () => 'wrong'), TypeError);
  assert.throws(() => addon.apply(4, () => 2 ** 53), RangeError);
  assert.throws(() => twice(1.5), RangeError);
  assert.throws(() => twice(undefined), TypeError);
  assert.throws(() => twice(Number.MAX_SAFE_INTEGER), RangeError);
  assert.equal(addon.applyDouble(1.5, () => 2), 2);

  let notified;
  assert.equal(addon.notify('notice', value => { notified = value; return 42; }), undefined);
  assert.equal(notified, 'notice');
  assert.equal(addon.numberRecorder()(19), undefined);
  assert.equal(addon.rememberedNumber(), 19);
  for (const text of ['中文 🌍', 'a\0b', '\ud800x\udfff']) {
    assert.equal(addon.applyText(text, value => value), text);
    assert.equal(addon.textEcho()(text), text);
  }
  assert.throws(() => addon.applyText('text', () => 1), TypeError);
  for (const value of [0n, -1n, 1n << 128n, -(1n << 200n)]) {
    assert.equal(addon.applyBigInt(value, item => item), value);
    assert.equal(addon.bigintEcho()(value), value);
  }
  assert.throws(() => addon.applyBigInt(1n, () => 1), TypeError);
  for (const error of [new Error('callback'), {}, Symbol('callback'), null, undefined]) {
    assert.throws(() => addon.apply(1, () => { throw error; }), actual => actual === error);
  }
  assert.equal(addon.apply(3, value => addon.apply(value, item => twice(item))), 6);

  const positional = addon.positionalCallback();
  assert.equal(positional(1), 21);
  assert.equal(positional(1, 2), 14);
  assert.equal(positional(1, 2, null), 3);
  assert.throws(() => positional(1, undefined), TypeError);
  assert.throws(() => positional(1, 2, undefined), TypeError);
  const positions = [];
  assert.deepEqual(addon.invokePositional((...args) => {
    positions.push(args);
    return args.length;
  }), [1, 2, 3]);
  assert.deepEqual(positions, [[1], [1, 2], [1, 2, null]]);

  const named = addon.namedCallback();
  assert.equal(named(1), '1|9|actual');
  assert.equal(named(1, {}), '1|9|actual');
  assert.equal(named(1, { note: null }), '1|9|null');
  assert.equal(named(1, { step: 2 }), '1|2|actual');
  assert.throws(() => named(1, undefined), TypeError);
  assert.throws(() => named(1, { step: undefined }), TypeError);
  const names = [];
  assert.deepEqual(addon.invokeNamed(function (...args) {
    names.push(args);
    return String(args.length);
  }), ['1', '2', '2', '2']);
  assert.deepEqual(names, [[1], [1, { step: 2 }], [1, { note: null }],
    [1, { step: 2, note: 'explicit' }]]);
  const required = addon.requiredNamedCallback();
  assert.equal(required({ value: 3 }), 7);
  assert.throws(() => required(), TypeError);
  assert.throws(() => required({}), TypeError);
  assert.throws(() => required(Object.create({ value: 3 })), TypeError);
  assert.equal(addon.invokeRequiredNamed(options => options.value + 1), 4);

  const calculator = new addon.Calculator(3);
  const operation = calculator.operation;
  assert.equal(operation(2), 6);
  assert.equal(calculator.operation, operation);
  assert.equal(calculator.apply(2, value => value + 1), 9);
  calculator.operation = original;
  assert.equal(calculator.operation, original);
  assert.equal(calculator.apply(2, value => value + 1), 13);
  assert.throws(() => { calculator.operation = undefined; }, TypeError);
  const functions = [original, twice];
  const copied = addon.echoCallbacks(functions);
  assert.notEqual(copied, functions);
  assert.equal(copied[0], original);
  assert.equal(copied[1], twice);
  assert.equal(addon.callbackMap({ first: original }).first, original);
  const box = new addon.Box(7);
  const select = addon.boxSelector(box);
  assert.equal(select(true), box);
  assert.equal(select(false), null);
  const nested = addon.nestedBoxes(box);
  assert.equal(nested()[0].item, box);
  assert.equal(nested()[0].empty, null);

  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('Dart Timer callback was not delivered')), 5000);
    addon.scheduleCallback(4, value => { clearTimeout(timeout); resolve(); return value + 3; });
  });
  assert.equal(addon.delayedResult(), 7, 'Callback lost its handle scope after Timer delivery');

  function retainInput() {
    const callback = value => value + 5;
    addon.saveCallback(callback);
    assert.equal(addon.savedCallback(), callback);
    return new WeakRef(callback);
  }
  const retained = retainInput();
  await nextTurn();
  global.gc();
  assert.notEqual(retained.deref(), undefined);
  assert.equal(addon.callSaved(2), 7);
  addon.clearCallback();
  assert.equal(addon.savedCallback(), null);

  // These readers exercise the application's weak payload cache while creating
  // real, escaping Dart allocations. Keep at most one pressure reader per turn.
  let pressureIndex = 0;
  function loadPressure(index) {
    assert.equal(addon.payloadReader(8 * 1024 * 1024 + index)(0), 0);
  }
  async function collected(weak, predicate, message) {
    for (let i = 0; i < 64; i++) {
      await nextTurn();
      loadPressure(pressureIndex++);
      global.gc();
      await nextTurn();
      if (weak.deref() === undefined && predicate()) return;
    }
    assert.fail(message);
  }
  await collected(retained, () => true, 'Released Dart callback kept the original JS function alive');

  function captureInput() {
    const callback = value => value + 1;
    const decorated = addon.decorate(callback, 2);
    assert.equal(decorated(3), 8);
    return [new WeakRef(decorated), new WeakRef(callback)];
  }
  const [decorated, captured] = captureInput();
  await collected(decorated, () => captured.deref() === undefined,
    'Collected Dart closure retained its captured JS callback');

  function cachePayload() {
    const reader = addon.payloadReader(1024);
    assert.equal(reader(0), 0);
    assert.equal(addon.hasCachedPayload(1024), true);
    return new WeakRef(reader);
  }
  await collected(cachePayload(), () => !addon.hasCachedPayload(1024),
    'Collected function kept its captured Dart payload alive');
};
