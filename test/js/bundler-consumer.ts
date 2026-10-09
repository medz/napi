import assert from 'node:assert/strict';
import {
  listInt,
  mapNullableString,
  listNullableBothDoubleAsync,
  mapNullableBothStringAsync,
} from '@napi/collections';
import { listInt as subpathListInt } from '@napi/collections/module.wasm';
import { listInt as relativeListInt } from './dist/module.wasm';

assert.equal(listInt, subpathListInt);
assert.equal(listInt, relativeListInt);
for (const fn of [listInt, mapNullableString, listNullableBothDoubleAsync, mapNullableBothStringAsync]) {
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

console.log(JSON.stringify({
  node: process.version, v8: process.versions.v8,
  nativeFunctions: 4, package: true, subpath: true, relative: true,
  copied: true, nullable: true, promise: true,
}));
