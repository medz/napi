import { Buffer } from 'node:buffer';
import { echoUsers, echoUsersAsync, echoNullableBothAsync, echoAlias, echoMapOnly, echoInline, echoPackets, echoNullablePacketsAsync, echoByteFields } from './dist/module.wasm';
import type { User, MaybeUserAlias, MapOnly, Packet, MaybePacket, ByteFields } from './dist/module.wasm';

const user: User = { name: 'Dart', age: 20, active: null };
const output: Record<string, User> = echoUsers({ id: user });
const pending: Promise<Record<string, User>> = echoUsersAsync({ id: user });
const nullable: Record<string, User | null> | null = await echoNullableBothAsync({ id: user, missing: null });
const alias: Record<string, MaybeUserAlias> = echoAlias({ id: user, missing: null });
const only: MapOnly = { label: 'relative', score: 1 };
const onlyOutput: Record<string, MapOnly> = echoMapOnly({ id: only });
const inline: Record<string, { label: string; count: number; flag: boolean | null; score: number } | null> | null = echoInline(null);
const packet: Packet = { name: 'relative', payload: Buffer.from([1, 2]) };
const packets: Record<string, Packet> = echoPackets({ id: packet });
const nullablePackets: Record<string, MaybePacket> | null = await echoNullablePacketsAsync({ id: packet, missing: null });
const fields: ByteFields = { first: packet.payload, maybe: null, second: packet.payload };
const fieldOutput: Record<string, ByteFields> = echoByteFields({ id: fields });
void [output, pending, nullable, alias, onlyOutput, inline, packets, nullablePackets, fieldOutput];

// @ts-expect-error Relative declarations retain required fields.
echoUsers({ id: { name: 'missing', age: 1 } });
// @ts-expect-error Nonnullable values exclude null.
echoUsers({ id: null });
// @ts-expect-error Nullable aliases exclude undefined.
echoAlias({ id: undefined });
// @ts-expect-error Relative byte records preserve typed-array types.
echoPackets({ id: { ...packet, payload: [1, 2] } });
// @ts-expect-error Byte field nullability is independent.
echoByteFields({ id: { ...fields, first: null } });
// @ts-expect-error Relative future output remains a Promise.
const synchronous: Record<string, User> = echoUsersAsync({ id: user });
