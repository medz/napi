import assert from 'node:assert/strict';
import {
  listInt,
  mapNullableString,
  listNullableBothDoubleAsync,
  mapNullableBothStringAsync,
  invertAll,
  listNullableBothBytesAsync,
} from '@napi/collections';
import { listInt as subpathListInt, invertAll as subpathInvertAll } from '@napi/collections/module.wasm';
import { listInt as relativeListInt, invertAll as relativeInvertAll } from './dist/module.wasm';

assert.equal(listInt, subpathListInt);
assert.equal(listInt, relativeListInt);
assert.equal(invertAll, subpathInvertAll);
assert.equal(invertAll, relativeInvertAll);
for (const fn of [listInt, mapNullableString, listNullableBothDoubleAsync, mapNullableBothStringAsync, invertAll, listNullableBothBytesAsync]) {
  assert.match(Function.prototype.toString.call(fn), /\[native code\]/);
}

const input = [1, 2];
const output: number[] = listInt(input);
assert.deepEqual(output, [1, 2]);
assert.notEqual(output, input);
output[0] = 42;
assert.equal(input[0], 1);
assert.deepEqual(listInt(input), [1, 2]);
assert.equal(output[0], 42);

const names: Record<string, string | null> = Object.assign(Object.create(null), {
  greeting: 'Aé😀\ud800\0', absent: null,
});
names.__proto__ = 'special key';
const labels: Record<string, string | null> = mapNullableString(names);
assert.deepEqual(labels, names);
assert.equal(Object.getPrototypeOf(labels), null);
assert.notEqual(labels, names);
labels.greeting = 'changed output';
assert.equal(names.greeting, 'Aé😀\ud800\0');

const values = [1.25, null, -0, NaN, Infinity];
const pending: Promise<Array<number | null> | null> = listNullableBothDoubleAsync(values);
assert(pending instanceof Promise);
values[0] = 99;
assert.deepEqual(await pending, [1.25, null, -0, NaN, Infinity]);
assert.equal(await listNullableBothDoubleAsync(null), null);
const pendingNames: Promise<Record<string, string | null> | null> = mapNullableBothStringAsync(names);
assert(pendingNames instanceof Promise);
names.greeting = 'changed input';
const completedNames = await pendingNames;
assert.equal(completedNames?.greeting, 'Aé😀\ud800\0');
assert.equal(Object.getPrototypeOf(completedNames), null);
assert.equal(await mapNullableBothStringAsync(null), null);
assert.throws(() => listInt([Number.MAX_SAFE_INTEGER + 1]), RangeError);
await assert.rejects(listNullableBothDoubleAsync([undefined] as never), TypeError);
assert.deepEqual(relativeListInt([42]), [42]);
const byteInput = new Uint8Array([0, 128, 255]);
const byteOutput: Uint8Array[] = relativeInvertAll(Object.freeze([byteInput, byteInput]));
assert.deepEqual(byteOutput, [new Uint8Array([255, 127, 0]), new Uint8Array([255, 127, 0])]);
assert.deepEqual(byteInput, new Uint8Array([0, 128, 255]));
assert.notEqual(byteOutput[0].buffer, byteOutput[1].buffer);
const bytePending: Promise<Array<Uint8Array | null> | null> = listNullableBothBytesAsync([byteInput, null]);
byteInput.fill(7);
assert.deepEqual(await bytePending, [new Uint8Array([0, 128, 255]), null]);
assert.equal(await listNullableBothBytesAsync(null), null);

console.log(JSON.stringify({
  node: process.version, v8: process.versions.v8,
  nativeFunctions: 6, package: true, subpath: true, relative: true,
  copied: true, bytes: true, nullable: true, promise: true,
}));
