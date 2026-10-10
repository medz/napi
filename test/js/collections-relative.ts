import {
  listInt, listNullableBothString, listNullableBothIntAsync,
  mapBool, mapNullableBothStringAsync,
  listBytes, listNullableBothBytesAsync, invertAll,
} from './dist/module.wasm';

type Equal<X, Y> = (<T>() => T extends X ? 1 : 2) extends (<T>() => T extends Y ? 1 : 2) ? true : false;
const exactInput: Equal<Parameters<typeof listInt>[0], readonly number[]> = true;
const exactNullableInput: Equal<Parameters<typeof listNullableBothIntAsync>[0], readonly (number | null)[] | null> = true;
const exactOutput: Equal<ReturnType<typeof listInt>, number[]> = true;
const exactAsyncOutput: Equal<ReturnType<typeof listNullableBothIntAsync>, Promise<Array<number | null> | null>> = true;
const exactByteInput: Equal<Parameters<typeof listBytes>[0], readonly Uint8Array[]> = true;
const exactByteOutput: Equal<ReturnType<typeof listBytes>, Uint8Array[]> = true;
const exactNullableByteInput: Equal<Parameters<typeof listNullableBothBytesAsync>[0], readonly (Uint8Array | null)[] | null> = true;
const exactBytePromise: Equal<ReturnType<typeof listNullableBothBytesAsync>, Promise<Array<Uint8Array | null> | null>> = true;
const byteInput = [new Uint8Array([0, 128, 255])] as const;
const bytes: Uint8Array[] = invertAll(byteInput);
const nullableBytes: Array<Uint8Array | null> | null = await listNullableBothBytesAsync(Object.freeze([new Uint8Array(), null]));
bytes[0][0] = 7; bytes.push(new Uint8Array()); nullableBytes?.push(null);
void [exactByteInput, exactByteOutput, exactNullableByteInput, exactBytePromise];
const input: readonly number[] = [1, 2];
const numbers: number[] = listInt(input);
const strings: Array<string | null> | null = listNullableBothString(['你好', null] as const);
const bools: Record<string, boolean> = mapBool({ yes: true });
const pending: Promise<Array<number | null> | null> = listNullableBothIntAsync(null);
const resolved: Array<number | null> | null = await listNullableBothIntAsync(Object.freeze([1, null]));
const completed: Record<string, string | null> | null = await mapNullableBothStringAsync({ greeting: 'hello', empty: null });
numbers[0] = 3;
numbers.push(4);
strings?.push('mutable');
if (resolved !== null) {
  resolved[0] = null;
  resolved.push(2);
}
void [exactInput, exactNullableInput, exactOutput, exactAsyncOutput, bools, pending, completed];

// @ts-expect-error Companion declarations preserve flat leaf types.
listInt([[1]]);
// @ts-expect-error Readonly arrays preserve scalar element types.
listInt([true] as const);
// @ts-expect-error Frozen nullable elements still exclude undefined.
listNullableBothIntAsync(Object.freeze([undefined]));
// @ts-expect-error Future completion is not a synchronous return value.
const wrongPromise: number[] | null = listNullableBothIntAsync([1]);
// @ts-expect-error Nullability excludes undefined.
listNullableBothString(undefined);
// @ts-expect-error Map values preserve their nullable scalar type.
mapNullableBothStringAsync({ value: false });
// @ts-expect-error Relative byte Lists preserve their Uint8Array leaves.
listBytes([new Uint16Array(1)]);
// @ts-expect-error Frozen nullable byte leaves still exclude undefined.
listNullableBothBytesAsync(Object.freeze([undefined]));
// @ts-expect-error Relative byte Future completion needs a Promise.
const wrongBytePromise: Uint8Array[] = listNullableBothBytesAsync(null);
