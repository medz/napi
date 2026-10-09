import { Buffer } from 'node:buffer';
import * as api from '@napi/records';
import { echoUser as subpathEcho, echoUserAsync as subpathAsync, echoPacket as subpathPacket, echoPacketAsync as subpathPacketAsync } from '@napi/records/module.wasm';
import type { User, UserAlias, NullableUser, MaybeUserAlias, ReexportUser, Mixed, SpecialFields, PartValue, Packet, PacketAlias, MaybePacket, ReexportPacket, ByteFields, PartPacket } from '@napi/records';
import type { User as SubpathUser } from '@napi/records/module.wasm';

const input: User = { name: 'Dart', age: 20, active: null };
const output: User = api.echoUser(input);
output.age = 21; // JavaScript output snapshots are mutable.
const normalized: User = api.normalizeUser(input);
const alias: UserAlias = api.echoAlias(input);
const aliasPending: Promise<UserAlias> = api.echoAliasAsync(input);
const reexported: ReexportUser = api.echoReexport(input);
const nullable: NullableUser = api.echoNullableAlias(null);
const nullablePending: Promise<NullableUser> = api.echoNullableAliasAsync(input);
const chained: MaybeUserAlias = api.echoChain(null);
const chainedPending: Promise<MaybeUserAlias> = api.echoChainAsync(input);
const asyncOutput: Promise<User | null> = api.echoUserAsync(input);
const completed: User | null = await asyncOutput;
const nullInput: User | null = await api.echoUserAsync(null);
const subpath: SubpathUser = subpathEcho(input);
const subpathPending: Promise<SubpathUser | null> = subpathAsync(null);
const typeAndValue: (value: User) => User = api.User;
const valueResult: User = typeAndValue(input);
const qualifiedType: api.User = api.User(input);

// Records are structural rather than branded; aliases with the same shape agree.
const extraFields = { ...input, ignored: { nested: true } };
const structural: UserAlias = api.echoUser(extraFields);
const readonlyInput: Readonly<User> = input;
const readonlyAccepted: User = api.echoUser(readonlyInput);
class UserData {
  name = 'Dart';
  age = 20;
  active: boolean | null = null;
}
// TS expresses shape, not the plain-own-data runtime boundary.
const classShape: User = api.echoUser(new UserData());

const mixed: Mixed = {
  flag: true, count: 42, value: NaN, text: '\ud800',
  maybeFlag: null, maybeCount: null, maybeValue: -0, maybeText: '你好',
};
const mixedOutput: Mixed = api.echoMixed(mixed);
const mixedPending: Promise<Mixed> = api.echoMixedAsync(mixed);
const special: SpecialFields = { constructor: 'own', prototype: '\ud800', then: 'scalar', $value: -0 };
const specialOutput: SpecialFields = api.echoSpecial(special);
const specialPending: Promise<SpecialFields> = api.echoSpecialAsync(special);
const part: PartValue = api.echoPart({ code: 7, message: 'part' });
const partPending: Promise<PartValue> = api.echoPartAsync(part);
const nullablePart: PartValue | null = api.echoPartNullable(null);
const nullablePartPending: Promise<PartValue | null> = api.echoPartNullableAsync(part);
const inline: { label: string; count: number; flag: boolean | null; score: number } = api.echoInline({ label: 'inline', count: 2, flag: null, score: Infinity });
const inlinePending: Promise<typeof inline | null> = api.echoInlineAsync(inline);
const inlineNull: typeof inline | null = await api.echoInlineAsync(null);
const one: { value: number } = api.inlineOne({ value: 42 });
const onePending: Promise<{ value: number }> = api.inlineOneAsync(one);
const tracked: User = api.tracked(input, input);
const trackedPending: Promise<User> = api.trackedAsync(input, input);
const stored: User = api.readStored();
const storedPending: Promise<User> = api.readStoredAsync();
const changed: void = api.changeStored();
const unsafe: User = api.unsafeUser();
const unsafePending: Promise<User> = api.unsafeUserAsync();
const unsafeMixed: Mixed = api.unsafeMixed();
const unsafeMixedPending: Promise<Mixed> = api.unsafeMixedAsync();
void [normalized, alias, aliasPending, reexported, nullable, nullablePending, chained, chainedPending, completed, nullInput, subpath, subpathPending, valueResult, qualifiedType, structural, readonlyAccepted, classShape, mixedOutput, mixedPending, specialOutput, specialPending, partPending, nullablePart, nullablePartPending, inlinePending, inlineNull, onePending, tracked, trackedPending, stored, storedPending, changed, unsafe, unsafePending, unsafeMixed, unsafeMixedPending];

// @ts-expect-error Nullable fields remain required.
api.echoUser({ name: 'Dart', age: 20 });
// @ts-expect-error Named fields retain exact scalar types.
api.echoUser({ name: 'Dart', age: '20', active: null });
// @ts-expect-error Required fields cannot be undefined.
api.echoUser({ name: 'Dart', age: 20, active: undefined });
// @ts-expect-error A nullable field does not make the record nullable.
api.echoUser(null);
// @ts-expect-error A nullable container never accepts undefined.
api.echoUserAsync(undefined);
// @ts-expect-error A nullable alias does not make fields optional.
api.echoNullableAlias({ name: 'Dart', age: 20 });
// @ts-expect-error Nullable RHS and alias chains exclude undefined.
api.echoChain(undefined);
// @ts-expect-error Fresh literals retain normal TS excess-property checks.
api.echoUser({ name: 'Dart', age: 20, active: null, extra: true });
// @ts-expect-error Nested values are not scalar record fields.
api.echoUser({ name: { nested: 'Dart' }, age: 20, active: null });
// @ts-expect-error Records do not become positional tuples.
api.echoUser(['Dart', 20, null]);
// @ts-expect-error Safe integer contracts still use number, not bigint.
api.echoUser({ name: 'Dart', age: 20n, active: null });
// @ts-expect-error Nonnullable mixed leaves reject null.
api.echoMixed({ ...mixed, count: null });
// @ts-expect-error Nullable mixed leaves remain strict.
api.echoMixed({ ...mixed, maybeFlag: 1 });
// @ts-expect-error All nullable mixed leaves remain required.
const missingMixed: Mixed = { flag: true, count: 1, value: 0, text: 'text' };
// @ts-expect-error Double fields require numbers.
api.echoMixed({ ...mixed, value: '0' });
// @ts-expect-error The then field is scalar, not a callback.
api.echoSpecial({ ...special, then() {} });
// @ts-expect-error Dollar-named fields preserve their type.
api.echoSpecial({ ...special, $value: false });
// @ts-expect-error Typedefs have no JavaScript value export.
const runtimeType = api.Mixed;
// @ts-expect-error Future results are Promise values.
const synchronous: User | null = api.echoUserAsync(input);
// @ts-expect-error Nullable results need a null check.
const nonnullable: User = await api.echoUserAsync(input);
// @ts-expect-error Nullable alias RHS survives the return declaration.
const nonnullableAlias: User = api.echoNullableAlias(input);
// @ts-expect-error Inline nullable completion survives Promise conversion.
const nonnullableInline: typeof inline = await api.echoInlineAsync(inline);
// @ts-expect-error Part-defined signatures preserve their required field.
api.echoPart({ code: 7 });
// @ts-expect-error Required positional parameters cannot be omitted.
api.echoUser();
// @ts-expect-error Type declarations check arity; raw Wasm ignores extra args.
api.echoUser(input, input);

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
