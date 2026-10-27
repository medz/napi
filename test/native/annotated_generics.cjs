'use strict';

const assert = require('node:assert/strict');
const { join } = require('node:path');
const { pathToFileURL } = require('node:url');

module.exports = async function verifyAnnotatedGenerics(path, packageDirectory) {
  const addon = require(path);
  const object = { value: 7 };
  const array = [object];
  const callback = value => value;
  const symbol = Symbol('generic');
  for (const value of [42, 'hello', object, array, callback, symbol, null, undefined]) {
    assert.equal(addon.identity(value), value);
  }
  assert.equal(addon.nullable(null), null);
  assert.equal(addon.nullable(object), object);
  const paired = addon.pair(object, 'hello');
  assert.equal(paired[0], object);
  assert.equal(paired[1], 'hello');
  const box = new addon.Box(object);
  assert.equal(addon.box.value, 0);
  addon.box = box;
  assert.equal(addon.box, box);
  assert.equal(box.value, object);
  assert.equal(box.echo(object), object);
  assert.equal(addon.echoBox(box), box);
  assert.equal(box.items[0], object);
  assert.equal(box.named.value, object);
  const next = { value: 9 };
  assert.equal(box.replace(next), object);
  assert.equal(box.value, next);
  box.value = object;
  assert.equal(box.value, object);
  const copied = addon.copyList(array);
  assert.notEqual(copied, array);
  assert.equal(copied[0], object);
  const map = { item: object };
  const copiedMap = addon.copyMap(map);
  assert.notEqual(copiedMap, map);
  assert.equal(copiedMap.item, object);
  assert.equal(addon.numeric(42), 42);
  assert.equal(addon.numeric(1.5), 1.5);
  assert.equal(addon.nullableNumeric(null), null);
  assert.equal(addon.nullableNumeric(7), 7);
  for (const value of ['7', null, undefined, object]) {
    assert.throws(() => addon.numeric(value), TypeError);
  }
  assert.throws(() => addon.nullableNumeric(undefined), TypeError);
  assert.equal(addon.nonNull(object), object);
  assert.equal(addon.nonNull(undefined), undefined);
  assert.throws(() => addon.nonNull(null), TypeError);
  assert.equal(addon.reference(object), object);
  assert.equal(addon.reference(callback), callback);
  assert.throws(() => addon.reference(symbol), TypeError);
  assert.equal(addon.apply(3, value => value + 1), 4);
  assert.equal(addon.apply(object, value => { assert.equal(value, object); return next; }), next);
  if (packageDirectory) {
    const common = require(join(packageDirectory, 'index.cjs'));
    const module = await import(pathToFileURL(join(packageDirectory, 'index.mjs')).href);
    assert.equal(module.default, common);
    assert.equal(module.Box, common.Box);
    assert.equal(Object.hasOwn(module, 'box'), false);
    const value = new module.Box(7);
    module.default.box = value;
    assert.equal(common.box, value);
    assert.equal(module.echoBox(value), value);
  }
};
