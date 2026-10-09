import assert from 'node:assert/strict';
import { normalizeUsers, normalizeUsersAsync, totalAge, echoNullableBothUsersAsync } from '@napi/batch';
import { normalizeUsers as subpath } from '@napi/batch/module.wasm';
import { normalizeUsers as relative } from './dist/module.wasm';
import type { User } from '@napi/batch';

assert.equal(normalizeUsers, subpath);
assert.equal(normalizeUsers, relative);
const users: User[] = [
  { name: ' Ada ', age: 42, active: null },
  { name: ' Lin ', age: 17, active: true },
];
const normalized: User[] = normalizeUsers(users);
assert.deepEqual(normalized.map(user => ({ ...user })), [
  { name: 'Ada', age: 42, active: false },
  { name: 'Lin', age: 17, active: true },
]);
assert.equal(totalAge(users), 59);
assert.equal(Object.getPrototypeOf(normalized[0]), null);
assert.notEqual(normalized, users);
assert.notEqual(normalized[0], users[0]);
const pending: Promise<User[]> = normalizeUsersAsync(users);
users[0].name = 'changed after call';
users.splice(1);
const snapshot = await pending;
assert.equal(snapshot.length, 2);
assert.equal(snapshot[0].name, 'Ada');
assert.equal(snapshot[1].name, 'Lin');
const nullable: Array<User | null> | null = await echoNullableBothUsersAsync([normalized[0], null]);
assert.equal(nullable?.[0]?.name, 'Ada');
assert.equal(nullable?.[1], null);
for (const fn of [normalizeUsers, normalizeUsersAsync, totalAge, echoNullableBothUsersAsync]) {
  assert.match(Function.prototype.toString.call(fn), /\[native code\]/);
}
console.log(JSON.stringify({ node: process.version, nativeFunctions: 4, normalized: true, totalAge: true, copied: true, snapshot: true, nullable: true }));
