'use strict';

const assert = require('node:assert/strict');
const { Worker } = require('node:worker_threads');

function worker(path) {
  return new Promise((resolve, reject) => {
    let message;
    const child = new Worker(`
      const { parentPort, workerData } = require('node:worker_threads');
      const addon = require(workerData);
      const session = new addon.Session('worker');
      addon.asyncObject().then(object => parentPort.postMessage({
        owner: session.sameOwner(), object, sync: addon.makeObject(13),
      }));
    `, { eval: true, workerData: path });
    const timeout = setTimeout(() => {
      child.terminate();
      reject(new Error('Injected Env worker did not exit'));
    }, 10000);
    child.on('error', reject);
    child.on('message', value => { message = value; });
    child.on('exit', code => {
      clearTimeout(timeout);
      try {
        assert.equal(code, 0);
        assert.deepEqual(message, { owner: true, object: { value: 11 }, sync: { value: 13 } });
        resolve();
      } catch (error) { reject(error); }
    });
  });
}

module.exports = async function verifyAnnotatedEnv(path) {
  const addon = require(path);
  assert.deepEqual(addon.makeObject(3), { value: 3 });
  const session = new addon.Session('normal');
  assert.equal(session.name, 'normal');
  assert.equal(session.count, 2);
  assert.equal(new addon.Session('explicit', 5).count, 5);
  assert.equal(session.sameOwner(), true);
  assert.equal(session.compute(1), 6);
  assert.deepEqual(addon.Session.create(7), { value: 7 });
  const derived = addon.derivedSession();
  assert.equal(derived.sameOwner(), true);
  assert.equal(derived.compute(1), 10);
  assert.equal(derived.compute(1, { b: 9 }), 15);
  assert.equal(derived.compute(1, { a: 7 }), 14);
  assert.equal(derived.compute(1, { get env() { throw new Error('Hidden Env read'); } }), 10);
  assert.throws(() => session.compute(1, { a: undefined }), TypeError);
  assert.deepEqual(await addon.asyncObject(), { value: 11 });
  assert.equal(addon.Stamp, undefined);
  assert.deepEqual(addon.echoStamp({
    value: 3, get env() { throw new Error('Hidden constructor Env read'); },
  }), { value: 3, object: { value: 3 } });
  await worker(path);
};
