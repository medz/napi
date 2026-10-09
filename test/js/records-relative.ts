import { Buffer } from 'node:buffer';
import * as api from './dist/module.wasm';
import { echoPacket as subpathPacket, echoPacketAsync as subpathPacketAsync } from './dist/module.wasm';
import { echoUser, echoUserAsync, echoNullableAlias, echoChainAsync, echoInline, echoInlineAsync, echoMixed, echoSpecialAsync, echoPart, User as userFunction } from './dist/module.wasm';
import type { User, UserAlias, NullableUser, MaybeUserAlias, Mixed, SpecialFields, PartValue, Packet, PacketAlias, MaybePacket, ReexportPacket, ByteFields, PartPacket } from './dist/module.wasm';

const input: User = { name: 'relative', age: 20, active: null };
const output: UserAlias = echoUser(input);
const pending: Promise<User | null> = echoUserAsync(input);
const nullable: NullableUser = echoNullableAlias(null);
const chained: MaybeUserAlias = await echoChainAsync(null);
const valueFunction: (value: User) => User = userFunction;
const valueOutput: User = valueFunction(input);
const inline: { label: string; count: number; flag: boolean | null; score: number } = echoInline({ label: 'x', count: 1, flag: null, score: -0 });
const inlinePending: Promise<typeof inline | null> = echoInlineAsync(null);
const mixed: Mixed = echoMixed({ flag: true, count: 2, value: NaN, text: '\ud800', maybeFlag: null, maybeCount: null, maybeValue: null, maybeText: null });
const special: SpecialFields = await echoSpecialAsync({ constructor: 'own', prototype: 'plain', then: 'scalar', $value: -0 });
const part: PartValue = echoPart({ code: 7, message: 'part' });
output.age = 21;
void [pending, nullable, chained, valueOutput, inlinePending, mixed, special, part];

// @ts-expect-error Relative declarations preserve required nullable fields.
echoUser({ name: 'relative', age: 20 });
// @ts-expect-error Relative declarations reject undefined containers.
echoUserAsync(undefined);
// @ts-expect-error Nullable alias fields are still required.
echoNullableAlias({ name: 'relative', age: 20 });
// @ts-expect-error Alias chains retain nullability, rather than making it void.
const nonnullable: User = await echoChainAsync(input);
// @ts-expect-error Future conversion retains its Promise type.
const synchronous: User | null = echoUserAsync(input);
// @ts-expect-error Inline named fields remain strict.
echoInline({ label: 'x', count: '1', flag: null, score: 0 });
// @ts-expect-error Scalar then fields do not become callbacks.
echoSpecialAsync({ constructor: 'x', prototype: 'y', then() {}, $value: 0 });
// @ts-expect-error Part-defined record shapes are precise.
echoPart({ code: 7, message: false });

// Uint8Array field typing reuses actual Node Buffer declarations.
type ByteEqual<X, Y> = (<T>() => T extends X ? 1 : 2) extends (<T>() => T extends Y ? 1 : 2) ? true : false;
const exactPacket: ByteEqual<Packet, { name: string; payload: Uint8Array }> = true;
const exactByteFields: ByteEqual<ByteFields, { first: Uint8Array; maybe: Uint8Array | null; second: Uint8Array }> = true;
const exactPacketPromise: ByteEqual<ReturnType<typeof api.echoPacketAsync>, Promise<Packet>> = true;
const exactMaybePacket: ByteEqual<ReturnType<typeof api.echoMaybePacketAsync>, Promise<MaybePacket>> = true;
const byteInput: Readonly<Packet> = Object.freeze({ name: ' packet ', payload: Buffer.from([0, 128, 255]) });
const byteOutput: Packet = api.normalizePacket(byteInput);
const bytePending: Promise<Packet> = api.normalizePacketAsync(byteInput);
const byteAlias: PacketAlias = api.echoPacketAlias(byteInput);
const byteReexport: ReexportPacket = byteAlias;
const maybePacket: MaybePacket = api.echoMaybePacket(null);
const maybePacketPending: Promise<MaybePacket> = api.echoMaybePacketAsync(byteInput);
const byteFields: ByteFields = api.echoByteFields({ first: new Uint8Array([1]), maybe: null, second: Buffer.from([2]) });
const byteFieldsPending: Promise<ByteFields> = api.echoByteFieldsAsync(byteFields);
const repeatedBytes: ByteFields = api.repeatByteFields(byteInput);
const repeatedBytesPending: Promise<ByteFields> = api.repeatByteFieldsAsync(byteInput);
const byteInline: { label: string; payload: Uint8Array | null } | null = api.echoInlineBytes({ label: 'inline', payload: null });
const byteInlinePending: Promise<typeof byteInline> = api.echoInlineBytesAsync({ label: 'inline', payload: Buffer.from([1]) });
const bytePart: PartPacket = api.echoPartPacket({ code: 1, payload: null });
const bytePartPending: Promise<PartPacket | null> = api.echoPartPacketAsync({ code: 1, payload: Buffer.from([1]) });
const byteSubpath: Packet = subpathPacket(byteInput);
const byteSubpathPending: Promise<Packet> = subpathPacketAsync(byteInput);
const byteTracked: Packet = api.trackedPacket(byteInput, byteInput);
const byteTrackedPending: Promise<Packet> = api.trackedPacketAsync(byteInput, byteInput);
const byteStored: Packet = api.readPacket();
const byteStoredPending: Promise<Packet> = api.readPacketAsync();
const byteChanged: void = api.changePacket();
byteOutput.name = 'mutable'; byteOutput.payload[0] = 1; byteOutput.payload = new Uint8Array([2]);
const byteCompleted: Packet = await bytePending;
byteCompleted.payload.fill(3);
if (byteFields.maybe !== null) byteFields.maybe[0] = 4;
void [exactPacket, exactByteFields, exactPacketPromise, exactMaybePacket, byteReexport, maybePacket, maybePacketPending, byteFieldsPending, repeatedBytes, repeatedBytesPending, byteInlinePending, bytePartPending, byteSubpath, byteSubpathPending, byteTracked, byteTrackedPending, byteStored, byteStoredPending, byteChanged];

// @ts-expect-error Byte fields remain required.
api.echoPacket({ name: 'missing' });
// @ts-expect-error Byte fields exclude undefined.
api.echoPacket({ name: 'invalid', payload: undefined });
// @ts-expect-error A nonnullable byte field excludes null.
api.echoPacket({ name: 'invalid', payload: null });
// @ts-expect-error Raw arrays are not Uint8Array views.
api.echoPacket({ name: 'invalid', payload: [1, 2] });
// @ts-expect-error ArrayBuffer is not a byte view.
api.echoPacket({ name: 'invalid', payload: new ArrayBuffer(2) });
// @ts-expect-error Wrong typed-array brands remain precise.
api.echoPacket({ name: 'invalid', payload: new Uint16Array(2) });
// @ts-expect-error DataView is not Uint8Array.
api.echoPacket({ name: 'invalid', payload: new DataView(new ArrayBuffer(2)) });
// @ts-expect-error Nullable fields are still required.
api.echoByteFields({ first: new Uint8Array(), second: new Uint8Array() });
// @ts-expect-error Nullable fields exclude undefined.
api.echoByteFields({ first: new Uint8Array(), maybe: undefined, second: new Uint8Array() });
// @ts-expect-error A nullable record alias does not permit undefined.
api.echoMaybePacket(undefined);
// @ts-expect-error Nullable record aliases retain required byte fields.
api.echoMaybePacket({ name: 'missing' });
// @ts-expect-error Inline nullable byte fields remain required.
api.echoInlineBytes({ label: 'missing' });
// @ts-expect-error Part aliases retain exact byte-view types.
api.echoPartPacket({ code: 1, payload: [] });
// @ts-expect-error Futures remain Promise completion values.
const synchronousPacket: Packet = api.echoPacketAsync(byteInput);
// @ts-expect-error Nullable Future completion needs a null check.
const nonnullablePacket: Packet = await api.echoMaybePacketAsync(byteInput);
// @ts-expect-error Byte typedefs remain type-only Wasm exports.
void api.Packet;
