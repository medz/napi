'use strict';

const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { pathToFileURL } = require('node:url');

module.exports = async function verifyAnnotatedConstants(path, packages = []) {
  const addon = require(path);
  assert.equal(addon.add(3), 5);
  assert.equal(addon.add(3, {}), 5);
  assert.equal(addon.add(3, { step: 4 }), 7);
  assert.throws(() => addon.add(3, { step: undefined }), TypeError);
  assert.equal(Object.hasOwn(addon, '_add'), false);
  assert(addon.point instanceof addon.Point);
  assert.equal(addon.point, addon.samePoint);
  assert.equal(addon.point.value, 3);
  assert.equal(addon.point.plus(), 4);
  assert.equal(new addon.Point().value, 7);
  const made = addon.makePoint();
  assert(made instanceof addon.Point);
  assert.equal(made.value, 7);
  assert.equal(addon.makePoint(9).value, 9);
  assert.throws(() => addon.makePoint(undefined), TypeError);
  assert.equal(Object.hasOwn(addon, 'absent'), true);
  assert.equal(addon.absent, null);
  assert.equal(addon.shown, 13);
  assert.equal(addon.viaHide, 17);
  assert.equal(Object.hasOwn(addon, 'hidden'), false);
  assert.equal(Object.hasOwn(addon, 'alias'), false);

  for (const name of ['add', 'point', 'samePoint', 'makePoint', 'absent', 'snapshot']) {
    const descriptor = Object.getOwnPropertyDescriptor(addon, name);
    assert.equal(descriptor.enumerable, true);
    assert.equal(descriptor.writable, false);
    assert.equal(descriptor.configurable, false);
  }
  assert.throws(() => { addon.point = made; }, TypeError);
  assert.equal(Reflect.deleteProperty(addon, 'absent'), false);
  const expected = {
    status: addon.Status.done, empty: null, items: [1, 2], map: { ['__proto__']: 3 },
  };
  assert.deepEqual(addon.snapshot, expected);
  assert.equal(Object.hasOwn(addon.snapshot.map, '__proto__'), true);
  addon.snapshot.items.push(5);
  addon.snapshot.map.__proto__ = 9;
  addon.snapshot.status = addon.Status.ready;
  assert.deepEqual(addon.snapshot.items, [1, 2, 5]);
  assert.equal(addon.snapshot.map.__proto__, 9);
  assert.deepEqual(addon.originalSnapshot(), expected);

  for (const directory of packages) {
    const metadata = JSON.parse(readFileSync(join(directory, '.napi.json'), 'utf8'));
    for (const name of ['add', 'point', 'samePoint', 'makePoint', 'absent', 'snapshot', 'shown', 'viaHide']) {
      assert.equal(metadata.exports.find(entry => entry.name === name).kind, 'value');
    }
    assert.equal(metadata.exports.some(entry => entry.name === 'hidden'), false);
    const common = require(join(directory, 'index.cjs'));
    const module = await import(pathToFileURL(join(directory, 'index.mjs')).href);
    assert.equal(module.point, common.point);
    assert.equal(module.samePoint, module.point);
    assert(module.point instanceof module.Point);
    assert.equal(module.add(3), 5);
    assert.equal(module.makePoint().value, 7);
    assert.equal(module.absent, null);
    assert.equal(module.shown, 13);
    assert.equal(module.hidden, undefined);
  }
};
