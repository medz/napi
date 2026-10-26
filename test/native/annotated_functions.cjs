'use strict';

const assert = require('node:assert/strict');

module.exports = function verifyAnnotatedFunctions(path) {
  const addon = require(path);
  for (const name of ['addNumbers', '_privateAnnotated', '_privateInt', '_privateText', 'unannotated']) {
    assert.equal(Object.hasOwn(addon, name), false);
  }
  assert.equal(addon.renamedAdd(20, 22), 42);
  assert.equal(addon.privateValue(17), 17);
  assert.throws(() => addon.renamedAdd(1), TypeError);
  assert.throws(() => addon.renamedAdd(1, undefined), TypeError);
  assert.throws(() => addon.renamedAdd(Number.MAX_SAFE_INTEGER, 1), RangeError);

  for (const [suffix, values] of [
    ['Bool', [true, false]],
    ['Int', [0, -1, Number.MIN_SAFE_INTEGER, Number.MAX_SAFE_INTEGER]],
    ['Double', [0, -0, 1, 1.5, NaN, Infinity, -Infinity]],
    ['Num', [0, -0, 1, 1.5, NaN, Infinity, -Infinity]],
    ['String', ['', '中文 🌍', 'a\0b', '\ud800x\udfff']],
    ['BigInt', [0n, 1n, -1n, 1n << 63n, (1n << 128n) - 1n, -(1n << 200n)]],
  ]) {
    for (const value of values) {
      assert.equal(addon[`echo${suffix}`](value), value);
      assert.equal(addon[`echoNullable${suffix}`](value), value);
    }
    assert.equal(addon[`echoNullable${suffix}`](null), null);
    for (const name of [`echo${suffix}`, `echoNullable${suffix}`]) {
      assert.throws(() => addon[name](), TypeError);
      assert.throws(() => addon[name](undefined), TypeError);
      assert.throws(() => addon[name]({}), TypeError);
    }
    assert.throws(() => addon[`echo${suffix}`](null), TypeError);
  }
  assert.equal(addon.echoNull(null), null);
  for (const args of [[], [undefined], [0], ['null']]) {
    assert.throws(() => addon.echoNull(...args), TypeError);
  }
  for (const name of ['echoInt', 'echoNullableInt']) {
    for (const value of [NaN, Infinity, -Infinity, 1.5, 2 ** 53, -(2 ** 53)]) {
      assert.throws(() => addon[name](value), RangeError);
    }
    for (const value of ['1', true, 1n]) {
      assert.throws(() => addon[name](value), TypeError);
    }
  }

  const privateText = '私有\0🌍\ud800';
  assert.equal(addon.positionalDefaults(3), `3|-7|${privateText}|-7`);
  assert.equal(addon.positionalDefaults(3, 2), `3|2|${privateText}|-7`);
  assert.equal(addon.positionalDefaults(3, 2, 'label'), '3|2|label|-7');
  assert.equal(addon.positionalDefaults(3, 2, 'label', null), '3|2|label|null');
  for (const args of [[], [undefined], [3, undefined], [3, 2, undefined],
    [3, 2, 'label', undefined], [3, null], [3, 2, null]]) {
    assert.throws(() => addon.positionalDefaults(...args), TypeError);
  }
  assert.equal(addon.namedDefaults(3, { count: 2 }), `3|2|${privateText}|-7`);
  assert.equal(addon.namedDefaults(3, { count: 2, maybe: null }), `3|2|${privateText}|null`);
  assert.equal(addon.optionalNamed(), '-7|-7');
  assert.equal(addon.optionalNamed({}), '-7|-7');
  assert.equal(addon.optionalNamed({ count: 2, maybe: null }), '2|null');
  for (const options of [undefined, null, { count: undefined }, { maybe: undefined }]) {
    assert.throws(() => addon.optionalNamed(options), TypeError);
  }
  for (const args of [[3], [3, undefined], [3, null], [3, {}],
    [3, { count: undefined }], [3, { count: 2, label: undefined }],
    [3, { count: 2, maybe: undefined }], [3, Object.create({ count: 2 })]]) {
    assert.throws(() => addon.namedDefaults(...args), TypeError);
  }
  const inherited = Object.assign(Object.create({ label: 'inherited', maybe: null }), { count: 2 });
  assert.equal(addon.namedDefaults(3, inherited), `3|2|${privateText}|-7`);
  assert.equal(addon.namedDefaults(3, Object.assign(Object.create(null), { count: 2 })),
    `3|2|${privateText}|-7`);
  const reads = { count: 0, label: 0, maybe: 0 };
  assert.equal(addon.namedDefaults(3, {
    get count() { ++reads.count; return 2; },
    get label() { ++reads.label; return 'once'; },
    get maybe() { ++reads.maybe; return null; },
    get unused() { throw new Error('Unknown options must not be read'); },
  }), '3|2|once|null');
  assert.deepEqual(reads, { count: 1, label: 1, maybe: 1 });
  for (const error of [new Error('getter'), {}, Symbol('getter'), null, undefined]) {
    let caught = false;
    try {
      addon.namedDefaults(3, { get count() { throw error; } });
    } catch (actual) {
      caught = true;
      assert.equal(actual, error);
    }
    assert(caught, 'Named getter exception was swallowed');
  }
  assert.equal(addon.remember(42), undefined);
  assert.equal(addon.readRemembered(), 42);
  assert.throws(() => addon.remember(undefined), TypeError);
  assert.equal(addon.readRemembered(), 42);
  assert.throws(() => addon.fail(), /annotated failure/);
  assert.equal(addon.renamedAdd(20, 22), 42);
};
