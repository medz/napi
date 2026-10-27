'use strict';

const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { pathToFileURL } = require('node:url');

module.exports = async function verifyAnnotatedProperties(path, packages = []) {
  const addon = require(path);
  assert.equal(addon.initializations(), 0);
  assert.equal(typeof Object.getOwnPropertyDescriptor(addon, 'lazyMutable').get, 'function');
  addon.lazyMutable = 20;
  assert.equal(addon.lazyMutable, 20);
  assert.equal(addon.initializations(), 0);
  const lazy = Object.getOwnPropertyDescriptor(addon, 'lazyFinal');
  assert.equal(typeof lazy.get, 'function');
  assert.equal(lazy.set, undefined);
  assert.equal(addon.initializations(), 0);
  assert.equal(lazy.get.call(addon, 123), 7);
  assert.equal(addon.lazyFinal, 7);
  assert.equal(addon.initializations(), 1);
  assert.throws(() => { addon.lazyFinal = 9; }, TypeError);
  assert.throws(() => addon.deferredFinal, /initialized/);
  assert.throws(() => { addon.deferredFinal = 9; }, TypeError);
  addon.initializeDeferred(11);
  assert.equal(addon.deferredFinal, 11);
  assert.equal(addon.count, 1);
  addon.count = 3;
  assert.equal(addon.count, 3);
  const count = Object.getOwnPropertyDescriptor(addon, 'count');
  assert.equal(count.get.call(addon, 123), 3);
  assert.throws(() => count.set.call(addon), TypeError);
  assert.equal(addon.count, 3);
  assert.throws(() => { addon.count = '3'; }, TypeError);
  assert.equal(addon.crossValue, 41);
  addon.crossValue = 12;
  assert.equal(addon.count, 12);
  assert.equal(addon.crossValue, 41);
  assert.equal(addon.nullableCount, null);
  addon.nullableCount = 7;
  assert.equal(addon.nullableCount, 7);
  addon.nullableCount = null;
  assert.throws(() => { addon.nullableCount = undefined; }, TypeError);
  assert.equal(addon.reads, 1);
  assert.equal(addon.reads, 2);
  assert.throws(() => { addon.reads = 9; }, TypeError);
  assert.equal(addon.writeOnly, undefined);
  addon.writeOnly = 13;
  assert.equal(addon.written(), 13);
  assert.equal(Object.getOwnPropertyDescriptor(addon, 'writeOnly').get, undefined);
  addon.display = 7;
  assert.equal(addon.display, '7');
  addon.display = null;
  assert.equal(addon.display, 'null');
  for (const reason of [{}, Symbol('setter'), null, undefined]) {
    let thrown = false;
    try { addon.rejected = reason; } catch (error) { thrown = true; assert.equal(error, reason); }
    assert(thrown, 'Setter did not throw its original value');
  }
  const operation = value => value * 3;
  addon.operation = operation;
  assert.equal(addon.operation, operation);
  assert.equal(addon.useOperation(4), 12);
  assert.deepEqual(addon.point, { value: 3 });
  addon.point = { value: '9' };
  assert.deepEqual(addon.point, { value: 9 });
  assert.throws(() => { addon.point = { value: 9 }; }, TypeError);
  const reason = {};
  assert.throws(() => { addon.point = { get value() { throw reason; } }; }, error => error === reason);
  const token = new addon.Token(5);
  addon.token = token;
  assert.equal(addon.token, token);
  assert.equal(addon.echoToken(addon.token), token);
  const object = {};
  addon.saved = object;
  assert.equal(addon.saved, object);
  assert.equal(addon.saved, object);
  addon.clearSaved();
  assert.equal(addon.saved, null);
  assert.throws(() => { addon.saved = undefined; }, TypeError);
  for (const name of ['hidden', 'hiddenAccessor', 'formatted', 'Point']) {
    assert.equal(Object.hasOwn(addon, name), false);
  }

  for (const directory of packages) {
    const common = require(join(directory, 'index.cjs'));
    assert.equal(common.initializations(), 0);
    const module = await import(pathToFileURL(join(directory, 'index.mjs')).href);
    assert.equal(common.initializations(), 0);
    assert.equal(module.default, common);
    assert.equal(module.Token, common.Token);
    assert.equal(module.twice, common.twice);
    assert.equal(module.fixed, common.fixed);
    for (const name of ['count', 'lazyFinal', 'deferredFinal', 'point', 'saved']) {
      assert.equal(Object.hasOwn(module, name), false);
    }
    module.default.count = 17;
    assert.equal(common.count, 17);
    common.count = 19;
    assert.equal(module.default.count, 19);
    assert.equal(common.lazyFinal, 7);
    assert.equal(common.initializations(), 1);
    const packageToken = new module.Token(7);
    module.default.token = packageToken;
    assert.equal(common.echoToken(common.token), packageToken);
    const metadata = JSON.parse(readFileSync(join(directory, '.napi.json'), 'utf8'));
    assert.equal(metadata.exports.find(entry => entry.name === 'count').kind, 'property');
  }
};
