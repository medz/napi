import { Buffer } from 'node:buffer';
import assert from 'node:assert/strict';
import { normalizeUsers, normalizeUsersAsync, totalAge, echoNullableBothUsersAsync, normalizePackets, normalizePacketsAsync, echoNullablePacketsAsync } from '@napi/batch';
import { normalizeUsers as subpath, normalizePackets as subpathPackets } from '@napi/batch/module.wasm';
import { normalizeUsers as relative, normalizePackets as relativePackets } from './dist/module.wasm';
import type { User, Packet, MaybePacket } from '@napi/batch';

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
assert.equal(normalizePackets, subpathPackets);
assert.equal(normalizePackets, relativePackets);
const packetBytes = Buffer.from([0, 128, 255]);
const packets = Object.freeze([Object.freeze({ name: ' packet ', payload: packetBytes })]);
const packetOutput: Packet[] = normalizePackets(packets);
assert.equal(packetOutput[0].name, 'packet');
assert.deepEqual(packetOutput[0].payload, new Uint8Array([255, 127, 0]));
assert.deepEqual(packetBytes, Buffer.from([0, 128, 255]));
assert.notEqual(packetOutput[0].payload.buffer, packetBytes.buffer);
packetOutput[0].payload[0] = 7;
assert.equal(packetBytes[0], 0);
const asyncBytes = new Uint8Array([0, 128, 255]);
const packetPending: Promise<Packet[]> = normalizePacketsAsync([{ name: ' packet ', payload: asyncBytes }] as const);
asyncBytes.fill(9);
const packetSnapshot = await packetPending;
assert.equal(packetSnapshot[0].name, 'packet');
assert.deepEqual(packetSnapshot[0].payload, new Uint8Array([255, 127, 0]));
const nullablePackets: MaybePacket[] | null = await echoNullablePacketsAsync([packetSnapshot[0], null] as const);
assert.equal(nullablePackets?.[0]?.payload[0], 255);
assert.equal(nullablePackets?.[1], null);
const nativeFunctions = [normalizeUsers, normalizeUsersAsync, totalAge, echoNullableBothUsersAsync, normalizePackets, normalizePacketsAsync, echoNullablePacketsAsync];
for (const fn of nativeFunctions) {
  assert.match(Function.prototype.toString.call(fn), /\[native code\]/);
}
console.log(JSON.stringify({ node: process.version, nativeFunctions: nativeFunctions.length, byteWorkflow: true, normalized: true, totalAge: true, copied: true, snapshot: true, nullable: true }));
