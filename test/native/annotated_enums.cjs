'use strict';

const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { pathToFileURL } = require('node:url');

module.exports = async function verifyAnnotatedEnums(path, packages = []) {
  const addon = require(path);
  assert.deepEqual(addon.Status, { ready: 0, done: 1 });
  assert.deepEqual(Object.keys(addon.Status), ['ready', 'done']);
  assert.equal(Object.hasOwn(addon.Status, '0'), false);
  assert.equal(Object.hasOwn(addon.Status, '1'), false);
  assert.throws(() => { addon.Status.ready = 9; }, TypeError);
  assert.deepEqual(addon.Mode, { fast: 0, slow: 1 });
  assert.equal(addon.modeCode(addon.Mode.fast), 7);
  assert.equal(addon.modeCode(addon.Mode.slow), 11);
  assert.equal(addon.echoStatus(0), addon.Status.ready);
  assert.equal(addon.echoStatus(1), addon.Status.done);
  assert.equal(addon.toggle(addon.Status.ready), addon.Status.done);
  assert.equal(addon.defaultStatus(), addon.Status.done);
  assert.equal(addon.defaultStatus(addon.Status.ready), addon.Status.ready);
  assert.equal(addon.nullableStatus(), null);
  assert.equal(addon.nullableStatus(null), null);
  assert.equal(addon.nullableStatus(addon.Status.done), addon.Status.done);

  for (const invalid of [0.5, NaN, Infinity, 9007199254740992]) {
    assert.throws(() => addon.echoStatus(invalid), RangeError);
  }
  for (const invalid of ['ready', 0n, {}, null, undefined]) {
    assert.throws(() => addon.echoStatus(invalid), TypeError);
  }
  for (const invalid of [-1, 2]) assert.throws(() => addon.echoStatus(invalid), TypeError);
  assert.throws(() => addon.nullableStatus(undefined), TypeError);
  assert.throws(() => addon.defaultStatus(undefined), TypeError);

  const job = new addon.Job();
  assert.equal(job.status, addon.Status.ready);
  job.status = addon.Status.done;
  job.next = addon.Status.ready;
  assert.equal(job.status, addon.Status.done);
  assert.equal(job.next, addon.Status.ready);
  assert.equal(job.finish(), addon.Status.done);
  assert.throws(() => { job.status = 2; }, TypeError);
  const inputs = [addon.Status.ready, null, addon.Status.done];
  const copied = addon.echoStatuses(inputs);
  assert.notEqual(copied, inputs);
  assert.deepEqual(copied, inputs);
  assert.deepEqual(addon.statusRecord({ status: addon.Status.ready, next: null }),
    { status: addon.Status.ready, next: null });
  assert.equal(addon.applyStatus(addon.Status.ready, value => value + 1), addon.Status.done);
  assert.throws(() => addon.applyStatus(addon.Status.ready, () => 2), TypeError);
  assert.equal(await addon.futureStatus(Promise.resolve(addon.Status.done)), addon.Status.done);
  await assert.rejects(addon.futureStatus(Promise.resolve(2)), TypeError);
  const values = [];
  for await (const value of addon.statuses()) values.push(value);
  assert.deepEqual(values, [addon.Status.ready, addon.Status.done]);

  for (const directory of packages) {
    const metadata = JSON.parse(readFileSync(join(directory, '.napi.json'), 'utf8'));
    for (const name of ['Status', 'Mode']) {
      assert.equal(metadata.exports.find(entry => entry.name === name).kind, 'enum');
    }
    const common = require(join(directory, 'index.cjs'));
    const module = await import(pathToFileURL(join(directory, 'index.mjs')).href);
    assert.deepEqual(common.Status, { ready: 0, done: 1 });
    assert.equal(module.Status, common.Status);
    assert.equal(module.toggle(module.Status.ready), module.Status.done);
    assert.equal(common.modeCode(common.Mode.fast), 7);
  }
};
