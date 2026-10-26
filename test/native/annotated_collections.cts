import addon = require('./addon');

const lists: Array<Array<number | null>> = addon.nestedLists([[1, null], []]);
const dictionary: Record<string, Array<number | null>> = addon.echoMap({ items: [1, null] });
const counter = new addon.Counter(1);
const counters: Array<addon.Counter | null> = addon.echoCounters([counter, null]);
const bytesAsList: number[] = addon.byteValues();
const fields = new addon.FieldMap();
fields.values = { items: [1, null] };
fields.optional = { empty: null };
fields.optional = null;
const optional: Record<string, number | null> | null = fields.optional;
const i8: Int8Array = addon.echoInt8(new Int8Array());
const u8: Uint8Array = addon.echoUint8(new Uint8Array());
const clamped: Uint8ClampedArray = addon.echoUint8Clamped(new Uint8ClampedArray());
const i16: Int16Array = addon.echoInt16(new Int16Array());
const u16: Uint16Array = addon.echoUint16(new Uint16Array());
const i32: Int32Array = addon.echoInt32(new Int32Array());
const u32: Uint32Array = addon.echoUint32(new Uint32Array());
const i64: BigInt64Array = addon.echoInt64(new BigInt64Array());
const u64: BigUint64Array = addon.echoUint64(new BigUint64Array());
const f32: Float32Array = addon.echoFloat32(new Float32Array());
const f64: Float64Array = addon.echoFloat64(new Float64Array());
const saved: Uint8Array = addon.saveBytes(new Uint8Array([1, 2]));
const read: Uint8Array = addon.savedBytes();
addon.changeSavedByte(0, 3);

// @ts-expect-error Nested element nullability does not include undefined.
addon.nestedLists([[undefined]]);
// @ts-expect-error String-keyed dictionaries use objects rather than JS Map.
addon.echoMap(new Map<string, number[]>());
// @ts-expect-error Class elements retain their declared type.
addon.echoCounters([1]);
// @ts-expect-error Nullable class elements do not accept undefined.
addon.echoCounters([undefined]);
// @ts-expect-error Nullable fields reject undefined.
fields.optional = undefined;
// @ts-expect-error Typed array kinds are preserved.
addon.echoUint8(new Int8Array());
// @ts-expect-error BigInt64 and BigUint64 remain distinct kinds.
addon.echoInt64(new BigUint64Array());
// @ts-expect-error Typed data is not an ordinary number array.
addon.echoUint8([1, 2]);
