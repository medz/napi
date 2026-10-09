import { Buffer } from 'node:buffer';
import * as api from '@napi/record-maps';
import { echoUsers as subpathUsers, echoPackets as subpathPackets } from '@napi/record-maps/module.wasm';
import type { User, MaybeUserAlias, MapOnly, Packet, MaybePacket, ByteFields, Mixed, SpecialFields } from '@napi/record-maps';
import type { User as SubpathUser, MapOnly as SubpathMapOnly } from '@napi/record-maps/module.wasm';

type Equal<X, Y> = (<T>() => T extends X ? 1 : 2) extends (<T>() => T extends Y ? 1 : 2) ? true : false;
const exactInput: Equal<Parameters<typeof api.echoUsers>[0], Record<string, User>> = true;
const exactOutput: Equal<ReturnType<typeof api.echoUsers>, Record<string, User>> = true;
const exactFuture: Equal<ReturnType<typeof api.echoUsersAsync>, Promise<Record<string, User>>> = true;
const exactNullableValues: Equal<Parameters<typeof api.echoNullableUsers>[0], Record<string, User | null>> = true;
const exactNullableContainer: Equal<Parameters<typeof api.echoNullableContainer>[0], Record<string, User> | null> = true;
const exactNullableBoth: Equal<ReturnType<typeof api.echoNullableBothAsync>, Promise<Record<string, User | null> | null>> = true;
const exactAlias: Equal<Parameters<typeof api.echoAlias>[0], Record<string, MaybeUserAlias>> = true;
const exactMapOnly: Equal<MapOnly, SubpathMapOnly> = true;

const user: User = { name: ' Dart ', age: 20, active: null };
const users: Record<string, User> = { alice: user };
const output: Record<string, User> = api.normalizeUsers(Object.freeze({ alice: Object.freeze(user) }));
const future: Promise<Record<string, User>> = api.echoUsersAsync(users);
const subpath: Record<string, SubpathUser> = subpathUsers(users);
const nullableValues: Record<string, User | null> = api.echoNullableUsers({ alice: user, missing: null });
const nullableContainer: Record<string, User> | null = api.echoNullableContainer(null);
const nullableBoth: Record<string, User | null> | null = await api.echoNullableBothAsync({ alice: user, missing: null });
const alias: Record<string, MaybeUserAlias> = await api.echoAliasAsync({ alice: user, missing: null });
const mapOnly: MapOnly = { label: 'map only', score: -0 };
const onlyOutput: Record<string, MapOnly> = api.echoMapOnly({ id: mapOnly });
type Inline = { label: string; count: number; flag: boolean | null; score: number };
const inline: Inline = { label: 'inline', count: 1, flag: null, score: Infinity };
const inlineOutput: Record<string, Inline | null> | null = await api.echoInlineAsync({ id: inline, missing: null });
const mixed: Mixed = { flag: true, count: 1, value: NaN, text: '\udfff', maybeFlag: null, maybeCount: null, maybeValue: -0, maybeText: null };
const mixedOutput: Record<string, Mixed> = api.echoMixed({ id: mixed });
const special: SpecialFields = { constructor: 'own', prototype: 'scalar', then: 'value', $value: -0 };
const specialOutput: Record<string, SpecialFields> = api.echoSpecial({ then: special });
const packet: Packet = { name: 'packet', payload: Buffer.from([0, 128, 255]) };
const packets: Record<string, Packet> = api.echoPackets({ id: packet });
const subpathBytes: Record<string, Packet> = subpathPackets({ id: packet });
const pendingBytes: Promise<Record<string, Packet>> = api.normalizePacketsAsync({ id: packet });
const nullableBytes: Record<string, MaybePacket> | null = await api.echoNullablePacketsAsync({ id: packet, missing: null });
const inlineBytes: Record<string, { name: string; payload: Uint8Array | null } | null> | null = api.echoInlinePackets({ id: { name: 'nullable', payload: null } });
const fields: ByteFields = { first: new Uint8Array([1]), maybe: null, second: Buffer.from([2]) };
const byteFields: Record<string, ByteFields> = api.echoByteFields({ id: fields });
output.alice.name = 'mutable'; output.bob = user;
onlyOutput.id.score = 1;
if (nullableBoth !== null) nullableBoth.new = null;
packets.id.payload[0] = 9;
void [exactInput, exactOutput, exactFuture, exactNullableValues, exactNullableContainer, exactNullableBoth, exactAlias, exactMapOnly, future, subpath, nullableValues, nullableContainer, alias, inlineOutput, mixedOutput, specialOutput, subpathBytes, pendingBytes, nullableBytes, inlineBytes, byteFields];

// @ts-expect-error Nullable fields remain required.
api.echoUsers({ id: { name: 'Dart', age: 20 } });
// @ts-expect-error Record fields retain their scalar types.
subpathUsers({ id: { ...user, age: '20' } });
// @ts-expect-error Integer fields use number, not bigint.
api.echoUsers({ id: { ...user, age: 20n } });
// @ts-expect-error Undefined is not a nullable record field.
api.echoUsers({ id: { ...user, active: undefined } });
// @ts-expect-error A nonnullable record value excludes null.
api.echoUsers({ id: null });
// @ts-expect-error A nullable container does not make values nullable.
api.echoNullableContainer({ id: null });
// @ts-expect-error A nullable value does not make the container nullable.
api.echoNullableUsers(null);
// @ts-expect-error Undefined is not a nullable value.
api.echoNullableBoth({ id: undefined });
// @ts-expect-error Undefined is not a nullable container.
api.echoNullableBoth(undefined);
// @ts-expect-error Alias RHS nullability preserves required fields.
api.echoAlias({ id: { name: 'Dart', age: 20 } });
// @ts-expect-error Map-only aliases retain their field types.
api.echoMapOnly({ id: { ...mapOnly, score: '1' } });
// @ts-expect-error Inline record fields retain their types.
api.echoInline({ id: { ...inline, count: '1' } });
// @ts-expect-error Only one Map layer is supported.
api.echoUsers({ id: { nested: user } });
// @ts-expect-error Arrays are not dictionaries of records.
api.echoUsers([user]);
// @ts-expect-error Native JS Map does not match the object contract.
api.echoUsers(new Map([['id', user]]));
// @ts-expect-error Promises are not materialized dictionaries.
api.echoUsersAsync(Promise.resolve(users));
// @ts-expect-error Future completions remain asynchronous.
const synchronous: Record<string, User> = api.echoUsersAsync(users);
// @ts-expect-error Nullable containers require a null check.
const nonnullable: Record<string, User | null> = await api.echoNullableBothAsync(users);
// @ts-expect-error Nullable aliases remain nullable in Map outputs.
const nonnullableAlias: Record<string, User> = api.echoAlias(users);
// @ts-expect-error Uint8List fields are typed as Uint8Array.
api.echoPackets({ id: { ...packet, payload: new Uint16Array([1]) } });
// @ts-expect-error Nullable bytes still exclude undefined.
api.echoInlinePackets({ id: { name: 'bad', payload: undefined } });
// @ts-expect-error Nullable byte fields remain required.
api.echoByteFields({ id: { first: fields.first, second: fields.second } });
// @ts-expect-error Public aliases are type-only exports.
const runtimeAlias = api.MapOnly;
// @ts-expect-error Required positional arguments cannot be omitted.
api.echoUsers();
// @ts-expect-error Declarations enforce arity.
api.echoUsers(users, users);
