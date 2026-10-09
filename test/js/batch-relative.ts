import { Buffer } from 'node:buffer';
import * as api from './dist/module.wasm';
import { echoPackets as subpathPackets } from './dist/module.wasm';
import { normalizeUsers, totalAge, echoUsers, echoNullableBothUsersAsync, echoNullableAlias, echoChain, echoInlineAsync, echoSpecialAsync, echoPart, echoReadonlyArrays } from './dist/module.wasm';
import type { User, UserAlias, MaybeUserAlias, SpecialFields, BatchPart, ReadonlyArray, Packet, MaybePacket, ByteFields, BatchPacket } from './dist/module.wasm';

type Equal<X, Y> = (<T>() => T extends X ? 1 : 2) extends (<T>() => T extends Y ? 1 : 2) ? true : false;
const exactInput: Equal<Parameters<typeof echoUsers>[0], readonly User[]> = true;
const exactNullableInput: Equal<Parameters<typeof echoNullableBothUsersAsync>[0], readonly (User | null)[] | null> = true;
const exactReadonlyArrayInput: Equal<Parameters<typeof echoReadonlyArrays>[0], readonly ReadonlyArray[]> = true;
const exactOutput: Equal<ReturnType<typeof echoReadonlyArrays>, ReadonlyArray[]> = true;
const exactAsyncOutput: Equal<ReturnType<typeof echoNullableBothUsersAsync>, Promise<Array<User | null> | null>> = true;

const user: User = { name: 'relative', age: 20, active: null };
const users: readonly User[] = [user];
const normalized: User[] = normalizeUsers(users);
const age: number = totalAge(normalized);
const chained: UserAlias[] = echoChain(normalized);
const nullableAlias: MaybeUserAlias[] = echoNullableAlias([user, null] as const);
const pending: Promise<Array<User | null> | null> = echoNullableBothUsersAsync(null);
const completed: Array<User | null> | null = await echoNullableBothUsersAsync(Object.freeze([Object.freeze(user), null]));
const inline: Array<{ label: string; count: number; flag: boolean | null; score: number } | null> | null = await echoInlineAsync([{ label: 'inline', count: 1, flag: null, score: -0 }, null] as const);
const special: SpecialFields[] = await echoSpecialAsync([{ constructor: 'own', prototype: 'plain', then: 'scalar', $value: -0 }]);
const part: Array<BatchPart | null> | null = echoPart([{ code: 7, message: 'part' }, null]);
const alias: ReadonlyArray = { count: 1 };
const aliasOutput: ReadonlyArray[] = echoReadonlyArrays(Object.freeze([alias]));
normalized[0].name = 'mutable';
normalized.push(user);
if (completed !== null) {
  if (completed[0] !== null) completed[0].age = 21;
  completed.push(null);
}
if (inline !== null) {
  if (inline[0] !== null) inline[0].label = 'mutable';
  inline.push(null);
}
aliasOutput[0].count = 2;
aliasOutput.push({ count: 3 });
void [exactInput, exactNullableInput, exactReadonlyArrayInput, exactOutput, exactAsyncOutput, age, chained, nullableAlias, pending, special, part];

// @ts-expect-error Relative declarations retain required nullable fields.
echoUsers([{ name: 'relative', age: 20 }]);
// @ts-expect-error Readonly rows retain required nullable fields.
echoUsers([{ name: 'relative', age: 20 }] as const);
// @ts-expect-error Frozen record arrays retain scalar fields.
echoUsers(Object.freeze([{ ...user, age: false }]));
// @ts-expect-error Readonly nullable rows exclude undefined.
echoNullableBothUsersAsync([user, undefined] as const);
// @ts-expect-error ReadonlyArray is a record alias, not an untyped array.
echoReadonlyArrays([{ count: false }] as const);
// @ts-expect-error A nullable element is not undefined.
echoNullableBothUsersAsync([undefined]);
// @ts-expect-error A nullable container is not undefined.
echoNullableBothUsersAsync(undefined);
// @ts-expect-error Nullable typedef RHS is preserved for each element.
const nonnullableAlias: User[] = echoNullableAlias([user]);
// @ts-expect-error Nullable containers and elements survive Promise conversion.
const synchronous: User[] = echoNullableBothUsersAsync([user]);
// @ts-expect-error The API permits one List layer.
echoUsers([[user]]);
// @ts-expect-error Scalar then is not a function.
echoSpecialAsync([{ constructor: 'x', prototype: 'y', then() {}, $value: 0 }]);
// @ts-expect-error Part type fields retain their scalar types.
echoPart([{ code: 7, message: false }]);

const exactPacketInput: Equal<Parameters<typeof api.echoPackets>[0], readonly Packet[]> = true;
const exactPacketOutput: Equal<ReturnType<typeof api.echoPackets>, Packet[]> = true;
const exactNullablePacketInput: Equal<Parameters<typeof api.echoNullablePacketsAsync>[0], readonly MaybePacket[] | null> = true;
const exactNullablePacketOutput: Equal<ReturnType<typeof api.echoNullablePacketsAsync>, Promise<MaybePacket[] | null>> = true;
const bytePacket: Readonly<Packet> = Object.freeze({ name: ' packet ', payload: Buffer.from([0, 128, 255]) });
const bytePackets: readonly Packet[] = [bytePacket];
const byteOutput: Packet[] = api.normalizePackets(bytePackets);
const bytePending: Promise<Packet[]> = api.normalizePacketsAsync(Object.freeze([bytePacket]));
const byteEcho: Packet[] = api.echoPackets([bytePacket] as const);
const byteEchoPending: Promise<Packet[]> = api.echoPacketsAsync(bytePackets);
const byteSubpath: Packet[] = subpathPackets([bytePacket] as const);
const maybePackets: MaybePacket[] | null = api.echoNullablePackets(null);
const maybePacketsPending: Promise<MaybePacket[] | null> = api.echoNullablePacketsAsync([bytePacket, null] as const);
const inlinePackets: Array<{ name: string; payload: Uint8Array | null } | null> | null = api.echoInlinePackets([{ name: 'inline', payload: null }, null] as const);
const inlinePacketsPending: Promise<typeof inlinePackets> = api.echoInlinePacketsAsync([{ name: 'inline', payload: Buffer.from([1]) }] as const);
const byteFields: ByteFields = { first: new Uint8Array([1]), maybe: null, second: Buffer.from([2]) };
const byteFieldsList: ByteFields[] = api.echoByteFieldsList([byteFields] as const);
const byteFieldsPending: Promise<ByteFields[]> = api.echoByteFieldsListAsync(Object.freeze([byteFields]));
const repeatedPackets: Packet[] = api.repeatFirstPacket(bytePackets);
const repeatedPacketsPending: Promise<Packet[]> = api.repeatFirstPacketAsync(bytePackets);
const bytePart: Array<BatchPacket | null> | null = api.echoPartPackets([{ code: 1, payload: null }, null] as const);
const bytePartPending: Promise<Array<BatchPacket | null> | null> = api.echoPartPacketsAsync([{ code: 1, payload: Buffer.from([1]) }] as const);
const byteTracked: Packet[] = api.trackedPackets(bytePackets, bytePackets);
const byteTrackedPending: Promise<Packet[]> = api.trackedPacketsAsync(bytePackets, bytePackets);
const byteStored: Packet[] = api.readPackets();
const byteStoredPending: Promise<Packet[]> = api.readPacketsAsync();
const byteChanged: void = api.changePackets();
byteOutput[0].name = 'mutable'; byteOutput[0].payload[0] = 1; byteOutput[0].payload = new Uint8Array([2]);
byteOutput.push({ name: 'appended', payload: new Uint8Array() });
const byteCompleted: Packet[] = await bytePending;
byteCompleted[0].payload.fill(3); byteCompleted.push(bytePacket);
if (bytePart !== null) { if (bytePart[0] !== null) bytePart[0].payload = new Uint8Array(); bytePart.push(null); }
void [exactPacketInput, exactPacketOutput, exactNullablePacketInput, exactNullablePacketOutput, byteEcho, byteEchoPending, byteSubpath, maybePackets, maybePacketsPending, inlinePacketsPending, byteFieldsList, byteFieldsPending, repeatedPackets, repeatedPacketsPending, bytePartPending, byteTracked, byteTrackedPending, byteStored, byteStoredPending, byteChanged];

// @ts-expect-error Readonly rows retain required byte fields.
api.echoPackets([{ name: 'missing' }] as const);
// @ts-expect-error Readonly rows retain exact byte-view types.
api.echoPackets([{ name: 'invalid', payload: [] }] as const);
// @ts-expect-error Wrong typed-array brands remain precise inside Lists.
subpathPackets([{ name: 'invalid', payload: new Uint16Array(2) }]);
// @ts-expect-error Nonnullable byte leaves exclude null.
api.echoPackets([{ name: 'invalid', payload: null }]);
// @ts-expect-error Nullable containers/elements do not permit undefined fields.
api.echoNullablePackets([{ name: 'invalid', payload: undefined }, null]);
// @ts-expect-error Nullable record elements exclude undefined.
api.echoNullablePacketsAsync([bytePacket, undefined] as const);
// @ts-expect-error Nullable containers exclude undefined.
api.echoNullablePackets(undefined);
// @ts-expect-error Nullable inline byte fields are still required.
api.echoInlinePackets([{ name: 'missing' }] as const);
// @ts-expect-error Nullable byte leaves exclude raw arrays.
api.echoInlinePacketsAsync([{ name: 'invalid', payload: [] }] as const);
// @ts-expect-error Repeated byte-field records keep all nullable fields required.
api.echoByteFieldsList([{ first: new Uint8Array(), second: new Uint8Array() }] as const);
// @ts-expect-error Part-defined byte fields retain their exact view type.
api.echoPartPackets([{ code: 1, payload: new DataView(new ArrayBuffer(1)) }]);
// @ts-expect-error Byte List Future outputs remain Promises.
const synchronousPackets: Packet[] = api.echoPacketsAsync(bytePackets);
// @ts-expect-error Nullable completion requires a null check.
const nonnullablePackets: Packet[] = await api.echoNullablePacketsAsync(null);
// @ts-expect-error Record type aliases have no native runtime export.
void api.Packet;
