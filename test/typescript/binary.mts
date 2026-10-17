import * as api from '@napi/binary-fixture';
import * as direct from '@napi/binary-fixture/BACKEND';
import * as external from '@napi/binary-external';

const bytes = new Uint8Array([1, 2]);
const buffer = bytes.buffer;
const copied: Uint8Array<ArrayBuffer> = api.bytes(bytes);
const raw: ArrayBuffer = api.buffer(buffer);
const subpath: Uint8Array<ArrayBuffer> = direct.bytes(bytes);
const selected: ArrayBuffer = external.buffer(buffer);
const optional: Uint8Array<ArrayBuffer> = api.optional();
api.optional(undefined); api.optional(null); api.optional(bytes);
api.named(); api.named(undefined); api.named({value: bytes, other: buffer});
api.named({value: null, other: null}); api.requiredNamed({value: bytes});
const nullable: Uint8Array<ArrayBuffer> | null = api.nullable(null);
const lists: (Uint8Array<ArrayBuffer> | null)[] = api.lists([bytes, null]);
const maps: Map<Uint8Array<ArrayBuffer>, ArrayBuffer> = api.maps(new Map([[bytes, buffer]]));
const dict: Record<string, Uint8Array<ArrayBuffer>> = api.dictionary({one: bytes});
const row: {$1: Uint8Array<ArrayBuffer>, data: ArrayBuffer} = api.record({$1: bytes, data: buffer});
const packet: api.Packet = api.packet({bytes, data: buffer});
const box = new api.BinaryBox(bytes, buffer);
box.bytes = bytes; box.data = null;
const read: Uint8Array<ArrayBuffer> = box.bytes;
const future: Promise<Uint8Array<ArrayBuffer>> = api.hold(1, bytes);
const futureBuffer: Promise<ArrayBuffer> = api.futureBuffer(buffer);
const futureRows: Promise<Uint8Array<ArrayBuffer>[]> = api.futureRows();
const owner = new api.BinaryOwner(1);
const stream: AsyncIterableIterator<Uint8Array<ArrayBuffer>> = owner.values;
const buffers: AsyncIterableIterator<ArrayBuffer> = owner.buffers;
const rows: AsyncIterableIterator<Uint8Array<ArrayBuffer>[]> = owner.rows;
const closed: Promise<void> = owner.close();
const shared = new SharedArrayBuffer(4);
const opaque: SharedArrayBuffer = api.opaque(shared);
const opaqueView: Uint8Array<SharedArrayBuffer> = api.opaque(new Uint8Array(shared));
// @ts-expect-error Required binary values retain presence.
api.bytes();
// @ts-expect-error Nullable does not admit undefined.
api.nullable(undefined);
// @ts-expect-error Nullable inputs remain required.
api.nullable();
// @ts-expect-error Non-null binary input rejects null.
api.bytes(null);
// @ts-expect-error Typed array and buffer are distinct input kinds.
api.bytes(buffer);
// @ts-expect-error Typed array and buffer are distinct input kinds.
api.buffer(bytes);
// @ts-expect-error Ordinary Array is not Uint8List.
api.bytes([1, 2]);
// @ts-expect-error Shared-backed typed arrays cannot cross the snapshot binding.
api.bytes(new Uint8Array(shared));
// @ts-expect-error SharedArrayBuffer is not ArrayBuffer.
api.buffer(shared);
// @ts-expect-error Unsupported typed arrays are not Uint8List.
api.bytes(new Uint16Array(1));
// @ts-expect-error Required named binary value cannot be omitted.
api.requiredNamed({});
// @ts-expect-error Required named binary value cannot be undefined.
api.requiredNamed({value: undefined});
// @ts-expect-error Nested binary leaves retain the same storage requirement.
api.lists([new Uint8Array(shared)]);
// @ts-expect-error Value-class binary fields remain required.
api.packet({bytes});
// @ts-expect-error Future results are Uint8Array, not raw ArrayBuffer.
const wrongFuture: Promise<ArrayBuffer> = api.hold(2, bytes);
// @ts-expect-error Stream getter remains readonly.
owner.values = stream;
void [copied, raw, subpath, selected, optional, nullable, lists, maps, dict, row,
  packet, read, future, futureBuffer, futureRows, stream, buffers, rows, closed, opaque, opaqueView, wrongFuture];
