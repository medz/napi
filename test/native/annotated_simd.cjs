'use strict';

const assert = require('node:assert/strict');

module.exports = function verifyAnnotatedSimd(path) {
  const addon = require(path);
  for (const [name, Type, lanes] of [
    ['Float32', Float32Array, 4], ['Int32', Int32Array, 4], ['Float64', Float64Array, 2],
  ]) {
    const values = Array.from({ length: lanes }, (_, index) => index + 1);
    const backing = new Type(lanes + 2);
    backing.set(values, 1);
    const input = backing.subarray(1, lanes + 1);
    const result = addon[`add${name}`](input);
    assert(result instanceof Type);
    assert.equal(result.byteLength, 16);
    assert.notEqual(result.buffer, input.buffer);
    assert.deepEqual(Array.from(result), values.map(value => value + 1));
    assert.throws(() => addon[`add${name}`](new Type(lanes - 1)));
    assert.throws(() => addon[`add${name}`](new Type(lanes + 1)));

    const flat = Array.from({ length: lanes * 2 }, (_, index) => index + 1);
    const storage = new Type(flat.length + 2);
    storage.set(flat, 1);
    const view = storage.subarray(1, flat.length + 1);
    const copied = addon[`echo${name}List`](view);
    assert(copied instanceof Type);
    assert.equal(copied.byteOffset, 0);
    assert.equal(copied.buffer.byteLength, 32);
    assert.notEqual(copied.buffer, view.buffer);
    assert.deepEqual(Array.from(copied), flat);
    view[0] = 99;
    copied[1] = 98;
    assert.equal(copied[0], 1);
    assert.equal(view[1], 2);
    assert.equal(addon[`echo${name}List`](new Type()).length, 0);
    assert.throws(() => addon[`echo${name}List`](new Type(lanes + 1)));
  }
  assert.throws(() => addon.addFloat32(new Int32Array(4)), TypeError);
  assert.throws(() => addon.addInt32(new Float32Array(4)), TypeError);
  assert.throws(() => addon.addFloat64(new Float32Array(2)), TypeError);
  assert.throws(() => addon.echoFloat32List(new Int32Array(4)), TypeError);
  assert.throws(() => addon.addFloat32([1, 2, 3, 4]), TypeError);
  const subview = addon.subview();
  assert.equal(subview.byteOffset, 0);
  assert.equal(subview.buffer.byteLength, 16);
  assert.deepEqual(Array.from(subview), [1, 2, 3, 4]);

  const bits = [0x7fc12345, 0x80000000, 0x3f800001, 0xffc54321];
  const input = new Float32Array(Uint32Array.from(bits).buffer);
  let callbackInput;
  const bounced = addon.bounceFloat32(value => { callbackInput = value; return value; });
  const output = bounced(input);
  assert.notEqual(callbackInput, input);
  assert.notEqual(output, callbackInput);
  assert.deepEqual(Array.from(new Uint32Array(callbackInput.buffer, callbackInput.byteOffset, 4)), bits);
  assert.deepEqual(Array.from(new Uint32Array(output.buffer, output.byteOffset, 4)), bits);
};
