'use strict';

const assert = require('node:assert/strict');
const { setImmediate: nextTurn } = require('node:timers/promises');
const { Worker } = require('node:worker_threads');
const { join } = require('node:path');
const { pathToFileURL } = require('node:url');

function worker(path) {
  return new Promise((resolve, reject) => {
    let message;
    const child = new Worker(`
      const { parentPort, workerData } = require('node:worker_threads');
      const { Base, Derived, Leaf, sharedBase } = require(workerData);
      const value = new Leaf(4);
      parentPort.postMessage([
        value instanceof Base, value instanceof Derived,
        Base.prototype.sum.call(value), Base.shared() === sharedBase(),
        Derived.shared() === sharedBase(),
      ]);
    `, { eval: true, workerData: path });
    const timeout = setTimeout(() => {
      child.terminate();
      reject(new Error('Inheritance worker did not exit'));
    }, 10000);
    child.on('error', reject);
    child.on('message', value => { message = value; });
    child.on('exit', code => {
      clearTimeout(timeout);
      try {
        assert.equal(code, 0);
        assert.deepEqual(message, [true, true, 22, true, true]);
        resolve();
      } catch (error) { reject(error); }
    });
  });
}

module.exports = async function verifyAnnotatedInheritance(path, packageDirectory) {
  const { Base, Derived, Leaf, GenericBase, NumDerived, NumericParent, WideChild,
    echoBase, echoDerived, sharedBase } = require(path);
  assert.equal(Object.getPrototypeOf(Derived.prototype), Base.prototype);
  assert.equal(Object.getPrototypeOf(Leaf.prototype), Derived.prototype);
  const base = new Base();
  const derived = new Derived();
  const leaf = new Leaf();
  assert(leaf instanceof Leaf && leaf instanceof Derived && leaf instanceof Base);
  assert.equal(base.sum(), 2);
  assert.equal(derived.sum(), 14);
  assert.equal(leaf.sum(), 20);
  assert.equal(leaf.extra(), 31);
  assert.equal(Base.prototype.sum.call(derived), 14);
  assert.equal(Base.prototype.sum.call(leaf, 1), 8);
  assert.equal(leaf.describe(), 'derived:6');
  assert.equal(leaf.describe({ label: 'custom' }), 'custom:6');
  assert.equal(Base.prototype.describe.call(leaf, { times: 4 }), 'derived:12');
  assert.equal(derived.readAlias(), 6);
  assert.equal(derived.readDerived(), 6);
  assert.equal(Base.prototype.readAlias.call(leaf), 9);
  assert.equal(Derived.prototype.readDerived.call(leaf), 9);
  assert.equal('aliased' in leaf, false);
  assert.equal(echoBase(leaf), leaf);
  assert.equal(echoDerived(leaf), leaf);
  assert.equal(leaf.same(), leaf);
  assert.equal(derived.onlyDerived(), 'derived');

  assert.equal(derived.level, 102);
  derived.level = 8;
  assert.equal(derived.level, 108);
  assert.equal(derived.value, 8);
  derived.stored = 6;
  assert.equal(derived.stored, 12);
  assert.equal(derived.value, 12);
  const level = Object.getOwnPropertyDescriptor(Base.prototype, 'level');
  assert.equal(level.get.call(derived), 112);
  level.set.call(derived, 9);
  assert.equal(derived.level, 109);

  class JavaScriptChild extends Leaf {}
  const javascript = new JavaScriptChild(4);
  assert.equal(Object.getPrototypeOf(javascript), JavaScriptChild.prototype);
  assert(javascript instanceof JavaScriptChild && javascript instanceof Leaf);
  assert.equal(javascript.sum(), 22);
  assert.equal(echoBase(javascript), javascript);
  for (const wrong of [{}, Object.create(Derived.prototype), new GenericBase()]) {
    assert.throws(() => Base.prototype.sum.call(wrong), TypeError);
    assert.throws(() => level.get.call(wrong), TypeError);
    assert.throws(() => echoBase(wrong), TypeError);
  }
  assert.throws(() => echoDerived(base), TypeError);

  const numeric = new NumDerived();
  assert(numeric instanceof GenericBase);
  assert.deepEqual(numeric.copy([1, 2.5]), [1, 2.5]);
  assert.deepEqual(GenericBase.prototype.copy.call(numeric, [1, 2.5]), [1, 2.5]);
  assert.throws(() => numeric.copy(['wrong']), TypeError);
  assert.throws(() => GenericBase.prototype.copy.call(numeric, ['wrong']), TypeError);
  assert.throws(() => numeric.copy([null]), TypeError);
  const wide = new WideChild();
  wide.accept('child contract');
  assert.equal(wide.last, 'child contract');
  assert.throws(() => NumericParent.prototype.accept.call(wide, 'wrong'), TypeError);
  assert.equal(wide.last, 'child contract');
  NumericParent.prototype.accept.call(wide, 1.5);
  assert.equal(wide.last, 1.5);

  let shared = Base.shared();
  assert(shared instanceof Derived && shared instanceof Base);
  assert.equal(shared.onlyDerived(), 'derived');
  assert.equal(sharedBase(), shared);
  assert.equal(Derived.shared(), shared);
  assert.equal(echoBase(shared), shared);
  assert.equal(echoDerived(shared), shared);
  const created = Base.created;
  assert.equal(Base.shared(), shared);
  assert.equal(Base.created, created);
  const weak = new WeakRef(shared);
  shared = null;
  for (let i = 0; i < 32; ++i) {
    await nextTurn();
    global.gc();
    await nextTurn();
    if (weak.deref() === undefined) break;
  }
  assert.equal(weak.deref(), undefined, 'An upcast retained the JavaScript wrapper');
  const rewrapped = sharedBase();
  assert(rewrapped instanceof Derived && rewrapped instanceof Base);
  assert.equal(rewrapped.value, 11);
  assert.equal(Base.shared(), rewrapped);
  assert.equal(Base.created, created);
  await worker(path);
  if (packageDirectory) {
    const common = require(join(packageDirectory, 'index.cjs'));
    const esm = await import(pathToFileURL(join(packageDirectory, 'index.mjs')).href);
    assert.equal(esm.default, common);
    assert.equal(esm.Base, common.Base);
    assert.equal(esm.Derived, common.Derived);
    const packaged = new esm.Leaf();
    assert(packaged instanceof esm.Base && packaged instanceof esm.Derived);
    assert.equal(esm.Base.prototype.sum.call(packaged), 20);
    assert.equal(esm.echoBase(packaged), packaged);
    assert.equal(esm.Derived.shared(), esm.sharedBase());
  }
};
