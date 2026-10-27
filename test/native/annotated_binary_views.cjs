'use strict';

const assert = require('node:assert/strict');
const viewBytes = view => Array.from(new Uint8Array(view.buffer, view.byteOffset, view.byteLength));

module.exports = function verifyAnnotatedBinaryViews(path) {
  const addon = require(path);
  const input = Uint8Array.from([1, 2, 3]);
  const buffer = addon.echoBuffer(input.buffer);
  assert(buffer instanceof ArrayBuffer);
  assert.notEqual(buffer, input.buffer);
  assert.deepEqual(Array.from(new Uint8Array(buffer)), [1, 2, 3]);
  input[0] = 7;
  new Uint8Array(buffer)[1] = 8;
  assert.deepEqual(Array.from(new Uint8Array(addon.lastBuffer())), [1, 2, 3]);
  assert.deepEqual(Array.from(input), [7, 2, 3]);
  assert.equal(addon.echoBuffer(new ArrayBuffer(0)).byteLength, 0);

  const backing = Uint8Array.from([91, 1, 2, 3, 92]);
  const view = new DataView(backing.buffer, 1, 3);
  const copied = addon.echoData(view);
  assert(copied instanceof DataView);
  assert.notEqual(copied, view);
  assert.equal(copied.byteOffset, 0);
  assert.equal(copied.buffer.byteLength, 3);
  assert.deepEqual(viewBytes(copied), [1, 2, 3]);
  backing[1] = 7;
  copied.setUint8(1, 8);
  assert.deepEqual(viewBytes(addon.lastData()), [1, 2, 3]);
  assert.deepEqual(Array.from(backing), [91, 7, 2, 3, 92]);
  const produced = addon.subview();
  assert.equal(produced.byteOffset, 0);
  assert.equal(produced.buffer.byteLength, 3);
  assert.deepEqual(viewBytes(produced), [1, 2, 3]);
  assert.equal(addon.echoData(new DataView(new ArrayBuffer(0))).byteLength, 0);

  for (const invalid of [view, input, {}, null, undefined, new SharedArrayBuffer(1)]) {
    assert.throws(() => addon.echoBuffer(invalid), TypeError);
  }
  for (const invalid of [input.buffer, input, {}, null, undefined]) {
    assert.throws(() => addon.echoData(invalid), TypeError);
  }
  const detachedBuffer = new ArrayBuffer(1);
  structuredClone(detachedBuffer, { transfer: [detachedBuffer] });
  assert.throws(() => addon.echoBuffer(detachedBuffer), TypeError);
  const detachedBacking = new ArrayBuffer(1);
  const detachedView = new DataView(detachedBacking);
  structuredClone(detachedBacking, { transfer: [detachedBacking] });
  assert.throws(() => addon.echoData(detachedView), TypeError);

  const shared = new Uint8Array(new SharedArrayBuffer(3));
  shared.set([4, 5, 6]);
  const sharedCopy = addon.echoData(new DataView(shared.buffer, 1, 1));
  assert(sharedCopy.buffer instanceof ArrayBuffer);
  assert.equal(sharedCopy.byteOffset, 0);
  assert.equal(sharedCopy.buffer.byteLength, 1);
  shared[1] = 9;
  assert.deepEqual(viewBytes(sharedCopy), [5]);
  assert.deepEqual(viewBytes(addon.lastData()), [5]);
  sharedCopy.setUint8(0, 7);
  assert.equal(shared[1], 9);

  const source = new DataView(Uint8Array.from([4, 5]).buffer);
  const views = [source, null];
  const result = addon.echoViews(views);
  assert.notEqual(result, views);
  assert.notEqual(result[0], source);
  assert.deepEqual(viewBytes(result[0]), [4, 5]);
  assert.equal(result[1], null);
  let callbackInput;
  const adapted = addon.bounceData(value => { callbackInput = value; return value; })(source);
  assert.notEqual(callbackInput, source);
  assert.notEqual(adapted, callbackInput);
  assert.deepEqual(viewBytes(adapted), [4, 5]);
};
