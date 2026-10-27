'use strict';

const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { pathToFileURL } = require('node:url');
const { spawnSync } = require('node:child_process');

module.exports = async function verifyAnnotatedObjects(path, packages = []) {
  const addon = require(path);
  assert.equal(Object.hasOwn(addon, 'Point'), false);
  assert.equal(Object.hasOwn(addon, 'Offset'), false);
  assert.equal(Object.hasOwn(addon, 'Readout'), false);
  const input = { value: '7' };
  const point = addon.echoPoint(input);
  const { serial, ...fields } = point;
  assert.deepEqual(fields, { value: 7, title: 'default', note: 'kept', next: null, child: null });
  assert.equal(typeof serial, 'number');
  assert.notEqual(point, input);
  assert.equal(addon.echoPoint({ value: '8' }).serial, serial + 1);
  assert.deepEqual(addon.echoOffset({}), { x: 3, y: 4 });
  assert.deepEqual(addon.echoOffset({ y: 9 }), { x: 3, y: 9 });
  assert.throws(() => addon.echoOffset({ x: undefined, y: 9 }), TypeError);
  assert.deepEqual(addon.readout(), { value: 9, values: [1] });

  point.value = 99;
  point.title = 'local';
  assert.equal(point.value, 99);
  assert.equal(point.title, 'local');
  assert.equal(Object.getOwnPropertyDescriptor(point, 'value').writable, true);
  const shared = addon.sharedPoint();
  shared.value = 99;
  const sharedAgain = addon.sharedPoint();
  assert.notEqual(sharedAgain, shared);
  assert.equal(sharedAgain.value, 3);
  assert.equal(sharedAgain.serial, shared.serial);

  const child = new addon.PointInput(5);
  const nested = addon.echoPoint({
    value: '1', label: 'outer', note: null, child,
    next: { value: '2', child },
  });
  assert.equal(nested.title, 'outer');
  assert.equal(nested.note, null);
  assert.equal(nested.child, child);
  assert.equal(nested.next.value, 2);
  assert.equal(nested.next.child, child);
  assert.equal(nested.next.next, null);
  assert.equal(addon.echoPoint({ value: '3', title: 'ignored' }).title, 'default');

  for (const invalid of [{}, { value: 7 }, { value: undefined }, null, undefined]) {
    assert.throws(() => addon.echoPoint(invalid), TypeError);
  }
  for (const name of ['label', 'note', 'next', 'child']) {
    assert.throws(() => addon.echoPoint({ value: '7', [name]: undefined }), TypeError);
  }
  let inherited = 0;
  const inheritedValue = Object.create({ get value() { inherited++; return '7'; } });
  assert.throws(() => addon.echoPoint(inheritedValue), TypeError);
  assert.equal(inherited, 0);
  let valueReads = 0, labelReads = 0, noteReads = 0;
  const getterPoint = addon.echoPoint({
    get value() { valueReads++; return '7'; },
    get label() { labelReads++; return 'once'; },
    get note() { noteReads++; return null; },
    get unused() { throw new Error('Extra input property was read'); },
  });
  assert.equal(getterPoint.value, 7);
  assert.equal(getterPoint.title, 'once');
  assert.deepEqual([valueReads, labelReads, noteReads], [1, 1, 1]);
  const reason = Symbol('getter');
  assert.throws(() => addon.echoPoint({ get value() { throw reason; } }), error => error === reason);
  const mutating = Object.create({ note: 'inherited' });
  Object.defineProperties(mutating, {
    value: { value: '7', enumerable: true },
    label: { get() { delete this.note; return 'delete'; }, enumerable: true },
    note: { value: 'own', configurable: true, enumerable: true },
  });
  assert.equal(addon.echoPoint(mutating).note, 'kept');

  const transformed = addon.transformPoint({ value: '3', child }, value => {
    assert.equal(value.value, 3);
    assert.equal(value.child, child);
    return { value: String(value.value + 1), child: value.child };
  });
  assert.equal(transformed.value, 4);
  assert.equal(transformed.child, child);
  const sharedInput = { value: '5', child };
  const entries = await addon.pointEntries(Promise.resolve({ one: sharedInput, two: sharedInput }));
  assert.equal(entries.length, 2);
  assert.equal(entries[0].key, 'one');
  assert.equal(entries[0].point.value, 5);
  assert.equal(entries[0].point.child, child);
  assert.equal(entries[1].point.value, 5);
  assert.notEqual(entries[0].point, entries[1].point);
  const streamed = [];
  for await (const value of addon.pointStream({ value: '6', child })) streamed.push(value);
  assert.equal(streamed[0].value, 6);
  assert.equal(streamed[0].child, child);

  const cycle = spawnSync(process.execPath, ['-e', `
    const assert = require('node:assert/strict');
    const addon = require(process.argv[1]);
    const input = { value: '1' };
    input.next = input;
    const rejected = error => error instanceof RangeError && /128 nested data objects/.test(error.message);
    assert.throws(() => addon.echoPoint(input), rejected);
    assert.throws(() => addon.cyclicPoint(), rejected);
    assert.equal(addon.echoPoint({ value: '7' }).value, 7);
  `, path], { encoding: 'utf8', timeout: 10000 });
  if (cycle.error) throw cycle.error;
  assert.equal(cycle.signal, null, cycle.stderr);
  assert.equal(cycle.status, 0, cycle.stderr);

  for (const directory of packages) {
    const metadata = JSON.parse(readFileSync(join(directory, '.napi.json'), 'utf8'));
    assert.equal(metadata.exports.find(entry => entry.name === 'Point').kind, 'type');
    assert.equal(metadata.exports.find(entry => entry.name === 'Readout').kind, 'type');
    const common = require(join(directory, 'index.cjs'));
    const module = await import(pathToFileURL(join(directory, 'index.mjs')).href);
    assert.equal(Object.hasOwn(common, 'Point'), false);
    assert.equal(Object.hasOwn(module, 'Point'), false);
    assert.equal(Object.hasOwn(module, 'Readout'), false);
    assert.equal(module.echoPoint({ value: '7' }).value, 7);
    const packageChild = new module.PointInput(9);
    assert.equal(common.echoPoint({ value: '1', child: packageChild }).child, packageChild);
  }
};
