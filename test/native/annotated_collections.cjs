'use strict';

const assert = require('node:assert/strict');

module.exports = function verifyAnnotatedCollections(path) {
  const addon = require(path);
  const versioned = new addon.Versioned();
  assert.equal(versioned.value, 1);
  versioned.value = 2;
  assert.equal(versioned.value, 1);
  const lists = [[1, null], [], [-2]];
  const copied = addon.nestedLists(lists);
  assert.deepEqual(copied, lists);
  assert.notEqual(copied, lists);
  assert.notEqual(copied[0], lists[0]);
  lists[0][0] = 9;
  copied[2].push(7);
  assert.equal(copied[0][0], 1);
  assert.deepEqual(lists[2], [-2]);
  for (const value of [undefined, {}, [undefined], [[undefined]]]) {
    assert.throws(() => addon.nestedLists(value), TypeError);
  }

  const previousProto = Object.getOwnPropertyDescriptor(Object.prototype, '__proto__');
  let setterCalls = 0;
  let itemsReads = 0;
  let protoReads = 0;
  try {
    Object.defineProperty(Object.prototype, '__proto__', {
      configurable: true,
      get: previousProto.get,
      set() { ++setterCalls; },
    });
    const input = Object.create({ get inherited() { throw new Error('Inherited key was read'); } });
    Object.defineProperties(input, {
      items: { enumerable: true, get() { ++itemsReads; return [1, null]; } },
      ['__proto__']: { enumerable: true, get() { ++protoReads; return [7, null]; } },
      hidden: { get() { throw new Error('Non-enumerable key was read'); } },
    });
    const output = addon.echoMap(input);
    assert.deepEqual(Object.keys(output).sort(), ['__proto__', 'items']);
    assert.deepEqual(output.items, [1, null]);
    assert.deepEqual(output.__proto__, [7, null]);
    assert.equal(Object.getPrototypeOf(output), Object.prototype);
    assert.equal(itemsReads, 1);
    assert.equal(protoReads, 1);
    assert.equal(setterCalls, 0);
  } finally {
    Object.defineProperty(Object.prototype, '__proto__', previousProto);
  }
  const error = {};
  assert.throws(() => addon.echoMap({ get broken() { throw error; } }), actual => actual === error);
  for (const value of [undefined, null, { missing: undefined }]) {
    assert.throws(() => addon.echoMap(value), TypeError);
  }
  let inheritedReads = 0;
  const changing = Object.create({
    get removed() { ++inheritedReads; return [99]; },
  });
  Object.defineProperties(changing, {
    first: { enumerable: true, get() { delete changing.removed; return [1]; } },
    removed: { enumerable: true, configurable: true, value: [2] },
  });
  assert.deepEqual(addon.echoMap(changing), { first: [1] });
  assert.equal(inheritedReads, 0);
  const fields = new addon.FieldMap();
  assert.deepEqual(fields.values, { default: [1, null] });
  assert.equal(fields.optional, null);
  const assigned = { items: [2, null] };
  fields.values = assigned;
  assigned.items[0] = 9;
  assert.deepEqual(fields.values, { items: [2, null] });
  const read = fields.values;
  read.items[0] = 8;
  assert.deepEqual(fields.values, { items: [2, null] });
  fields.optional = { empty: null };
  assert.deepEqual(fields.optional, { empty: null });
  fields.optional = null;
  assert.equal(fields.optional, null);
  assert.throws(() => { fields.optional = undefined; }, TypeError);
  assert.throws(() => new addon.FieldMap(undefined), TypeError);

  const a = new addon.Counter(1);
  const b = new addon.Counter(2);
  const counters = [a, null, b, a];
  const result = addon.echoCounters(counters);
  assert.notEqual(result, counters);
  assert.equal(result[0], a);
  assert.equal(result[1], null);
  assert.equal(result[2], b);
  assert.equal(result[3], a);
  result[0] = null;
  counters[2] = null;
  assert.equal(counters[0], a);
  assert.equal(result[2], b);
  result[3].value = 7;
  assert.equal(a.value, 7);
  assert.throws(() => addon.echoCounters([undefined]), TypeError);
  const ordinaryBytes = addon.byteValues();
  assert(Array.isArray(ordinaryBytes));
  assert.deepEqual(ordinaryBytes, [1, 2]);

  for (const [name, Type, values] of [
    ['Int8', Int8Array, [-128, 0, 127]],
    ['Uint8', Uint8Array, [0, 128, 255]],
    ['Uint8Clamped', Uint8ClampedArray, [0, 128, 255]],
    ['Int16', Int16Array, [-32768, 0, 32767]],
    ['Uint16', Uint16Array, [0, 32768, 65535]],
    ['Int32', Int32Array, [-2147483648, 0, 2147483647]],
    ['Uint32', Uint32Array, [0, 2147483648, 4294967295]],
    ['Int64', BigInt64Array, [-(1n << 63n), 0n, (1n << 63n) - 1n]],
    ['Uint64', BigUint64Array, [0n, 1n << 63n, (1n << 64n) - 1n]],
    ['Float32', Float32Array, [-0, 0.25, Infinity]],
    ['Float64', Float64Array, [-0, Number.MIN_VALUE, NaN]],
  ]) {
    const storage = new Type(values.length + 2);
    storage.set(values, 1);
    const view = storage.subarray(1, 1 + values.length);
    const output = addon[`echo${name}`](view);
    assert(output instanceof Type);
    assert.notEqual(output.buffer, view.buffer);
    assert.deepEqual(Array.from(output), values);
    const empty = addon[`echo${name}`](storage.subarray(2, 2));
    assert(empty instanceof Type);
    assert.equal(empty.length, 0);
  }
  assert.throws(() => addon.echoUint8(new Int8Array()), TypeError);
  assert.throws(() => addon.echoInt64(new BigUint64Array()), TypeError);
  assert.throws(() => addon.echoUint8(undefined), TypeError);
  assert.throws(() => addon.echoUint8([1, 2]), TypeError);
  const bytes = Uint8Array.from([0, 1, 2, 3, 4]);
  const saved = addon.saveBytes(bytes.subarray(1, 4));
  assert.deepEqual(Array.from(saved), [1, 2, 3]);
  bytes[1] = 9;
  saved[1] = 8;
  assert.deepEqual(Array.from(addon.savedBytes()), [1, 2, 3]);
  addon.changeSavedByte(2, 7);
  assert.equal(saved[2], 3);
  assert.deepEqual(Array.from(addon.savedBytes()), [1, 2, 7]);
};
