import * as api from '@napi/shared-bytes-fixture';
import * as direct from '@napi/shared-bytes-fixture/BACKEND';
import * as external from '@napi/shared-bytes-external';
const bytes = new Uint8Array([1, 2]);
const result: Uint8Array<ArrayBuffer> = api.remember(bytes);
const raw: Uint8Array<ArrayBuffer> = direct.allocate(2);
const selected: Uint8Array<ArrayBuffer> = external.remember(bytes);
const copied: Uint8Array<ArrayBuffer> = api.snapshot();
const nullable: Uint8Array<ArrayBuffer> | null = api.nullable(null);
api.optional(); api.optional(undefined); api.optional(null); api.optional(bytes);
api.named(); api.named(undefined); api.named({value: bytes}); api.named({value: null});
api.requiredNamed({value: bytes});
const list: (Uint8Array<ArrayBuffer> | null)[] = api.lists([bytes, null]);
const map: Map<Uint8Array<ArrayBuffer>, Uint8Array<ArrayBuffer>> = api.maps(new Map([[bytes, bytes]]));
const dict: Record<string, Uint8Array<ArrayBuffer>> = api.dictionary({one: bytes});
const row: {$1: Uint8Array<ArrayBuffer>, other: Uint8Array<ArrayBuffer> | null} = api.record({$1: bytes, other: null});
const packet: api.SharedPacket = api.packet({bytes});
const box = new api.SharedBox(bytes);
box.bytes = bytes; box.change(1);
const allocated = api.SharedBox.allocated(2);
const promise: Promise<Uint8Array<ArrayBuffer>> = api.hold(1, bytes);
const owner = new api.SharedOwner(1);
const stream: AsyncIterableIterator<Uint8Array<ArrayBuffer>> = owner.values;
const rows: AsyncIterableIterator<Uint8Array<ArrayBuffer>[]> = owner.rows;
const close: Promise<void> = owner.close();
// @ts-expect-error Required input retains presence.
api.remember();
// @ts-expect-error SharedBytes is Uint8Array, not ArrayBuffer.
api.remember(bytes.buffer);
// @ts-expect-error Shared backing is unsupported.
api.remember(new Uint8Array(new SharedArrayBuffer(1)));
// @ts-expect-error Other typed-array kinds are unsupported.
api.remember(new Uint16Array(1));
// @ts-expect-error Non-null input rejects null.
api.remember(null);
// @ts-expect-error Required nullable still rejects undefined.
api.nullable(undefined);
// @ts-expect-error Required named value cannot be omitted.
api.requiredNamed({});
// @ts-expect-error Required named value rejects undefined.
api.requiredNamed({value: undefined});
// @ts-expect-error Value-class field remains required.
api.packet({});
// @ts-expect-error Stream output is readonly.
owner.values = stream;
void [result, raw, selected, copied, nullable, list, map, dict, row, packet, allocated, promise, stream, rows, close];
