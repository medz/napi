import * as api from '@napi/collections';
import { listInt as subpathListInt, listNullableBothIntAsync as subpathNullableList, mapNullableBothStringAsync as subpathMap, listBytes as subpathBytes, listNullableBothBytesAsync as subpathNullableBytes } from '@napi/collections/module.wasm';

type Equal<X, Y> = (<T>() => T extends X ? 1 : 2) extends (<T>() => T extends Y ? 1 : 2) ? true : false;
const exactInput: Equal<Parameters<typeof api.listInt>[0], readonly number[]> = true;
const exactAsyncInput: Equal<Parameters<typeof api.listIntAsync>[0], readonly number[]> = true;
const exactNullableElements: Equal<Parameters<typeof api.listNullableInt>[0], readonly (number | null)[]> = true;
const exactNullableContainer: Equal<Parameters<typeof api.listNullableContainerInt>[0], readonly number[] | null> = true;
const exactNullableBoth: Equal<Parameters<typeof api.listNullableBothIntAsync>[0], readonly (number | null)[] | null> = true;
const exactOutput: Equal<ReturnType<typeof api.listInt>, number[]> = true;
const exactAsyncOutput: Equal<ReturnType<typeof api.listIntAsync>, Promise<number[]>> = true;
const readonlyNumbers: readonly number[] = [42];
const readonlyNullableNumbers: readonly (number | null)[] = [42, null];
const exactByteInput: Equal<Parameters<typeof api.listBytes>[0], readonly Uint8Array[]> = true;
const exactNullableByteInput: Equal<Parameters<typeof api.listNullableBytes>[0], readonly (Uint8Array | null)[]> = true;
const exactByteContainer: Equal<Parameters<typeof api.listNullableContainerBytes>[0], readonly Uint8Array[] | null> = true;
const exactByteBoth: Equal<Parameters<typeof subpathNullableBytes>[0], readonly (Uint8Array | null)[] | null> = true;
const exactByteOutput: Equal<ReturnType<typeof api.listBytes>, Uint8Array[]> = true;
const exactBytePromise: Equal<ReturnType<typeof api.listBytesAsync>, Promise<Uint8Array[]>> = true;
const exactNullableBytePromise: Equal<ReturnType<typeof subpathNullableBytes>, Promise<Array<Uint8Array | null> | null>> = true;
const readonlyBytes: readonly Uint8Array[] = [new Uint8Array([1, 2])];
const bytes: Uint8Array[] = api.listBytes(readonlyBytes);
const bytesLater: Promise<Uint8Array[]> = api.listBytesAsync(readonlyBytes);
const nullableBytes: Array<Uint8Array | null> = api.listNullableBytes([new Uint8Array(), null] as const);
const nullableBytesLater: Promise<Array<Uint8Array | null>> = api.listNullableBytesAsync([null]);
const nullableByteContainer: Uint8Array[] | null = api.listNullableContainerBytes(null);
const nullableByteContainerLater: Promise<Uint8Array[] | null> = api.listNullableContainerBytesAsync(null);
const nullableByteBoth: Array<Uint8Array | null> | null = api.listNullableBothBytes(null);
const subpathByteOutput: Uint8Array[] = subpathBytes(Object.freeze(readonlyBytes));
const nullableByteResolved: Array<Uint8Array | null> | null = await subpathNullableBytes(Object.freeze([new Uint8Array(), null]));
bytes[0][0] = 3; bytes.push(new Uint8Array());
subpathByteOutput.push(new Uint8Array());
nullableByteResolved?.push(null);
void [exactByteInput, exactNullableByteInput, exactByteContainer, exactByteBoth, exactByteOutput,
  exactBytePromise, exactNullableBytePromise, bytesLater, nullableBytes, nullableBytesLater,
  nullableByteContainer, nullableByteContainerLater, nullableByteBoth];

// @ts-expect-error Byte List leaves are Uint8Array values rather than integers.
api.listBytes([1]);
// @ts-expect-error Other typed arrays preserve their distinct element type.
api.listBytes([new Uint16Array(1)]);
// @ts-expect-error The outer container is a JavaScript Array.
api.listBytes(new Uint8Array(1));
// @ts-expect-error Nullable byte leaves still exclude undefined.
subpathNullableBytes([undefined]);
// @ts-expect-error Nullable byte containers do not permit null leaves.
api.listNullableContainerBytes([null]);
// @ts-expect-error Nullable byte leaves do not permit a null container.
api.listNullableBytes(null);
// @ts-expect-error Only one List layer is supported.
api.listBytes([[new Uint8Array()]]);
// @ts-expect-error Future byte Lists remain Promise values.
const synchronousBytes: Uint8Array[] = api.listBytesAsync(readonlyBytes);

const listBool: Array<boolean> = api.listBool([true] as const);
const listBoolAsync: Promise<Array<boolean>> = api.listBoolAsync([true]);
const listNullableBool: Array<boolean | null> = api.listNullableBool([true, null]);
const listNullableBoolAsync: Promise<Array<boolean | null>> = api.listNullableBoolAsync([true, null]);
const listNullableContainerBool: Array<boolean> | null = api.listNullableContainerBool([true]);
const listNullableContainerBoolAsync: Promise<Array<boolean> | null> = api.listNullableContainerBoolAsync([true]);
void api.listNullableContainerBool(null);
const listNullableBothBool: Array<boolean | null> | null = api.listNullableBothBool([true, null]);
const listNullableBothBoolAsync: Promise<Array<boolean | null> | null> = api.listNullableBothBoolAsync([true, null]);
void api.listNullableBothBool(null);
const listInt: Array<number> = api.listInt(readonlyNumbers);
const listIntAsync: Promise<Array<number>> = api.listIntAsync(readonlyNumbers);
const listNullableInt: Array<number | null> = api.listNullableInt(readonlyNullableNumbers);
const listNullableIntAsync: Promise<Array<number | null>> = api.listNullableIntAsync(readonlyNullableNumbers);
const listNullableContainerInt: Array<number> | null = api.listNullableContainerInt(readonlyNumbers);
const listNullableContainerIntAsync: Promise<Array<number> | null> = api.listNullableContainerIntAsync(readonlyNumbers);
void api.listNullableContainerInt(null);
const listNullableBothInt: Array<number | null> | null = api.listNullableBothInt(readonlyNullableNumbers);
const listNullableBothIntAsync: Promise<Array<number | null> | null> = api.listNullableBothIntAsync(readonlyNullableNumbers);
void api.listNullableBothInt(null);
const listDouble: Array<number> = api.listDouble(Object.freeze([Infinity]));
const listDoubleAsync: Promise<Array<number>> = api.listDoubleAsync([Infinity]);
const listNullableDouble: Array<number | null> = api.listNullableDouble([Infinity, null]);
const listNullableDoubleAsync: Promise<Array<number | null>> = api.listNullableDoubleAsync([Infinity, null]);
const listNullableContainerDouble: Array<number> | null = api.listNullableContainerDouble([Infinity]);
const listNullableContainerDoubleAsync: Promise<Array<number> | null> = api.listNullableContainerDoubleAsync([Infinity]);
void api.listNullableContainerDouble(null);
const listNullableBothDouble: Array<number | null> | null = api.listNullableBothDouble([Infinity, null]);
const listNullableBothDoubleAsync: Promise<Array<number | null> | null> = api.listNullableBothDoubleAsync([Infinity, null]);
void api.listNullableBothDouble(null);
const listString: Array<string> = api.listString(['你好\ud800'] as const);
const listStringAsync: Promise<Array<string>> = api.listStringAsync(['你好\ud800']);
const listNullableString: Array<string | null> = api.listNullableString(['你好\ud800', null]);
const listNullableStringAsync: Promise<Array<string | null>> = api.listNullableStringAsync(['你好\ud800', null]);
const listNullableContainerString: Array<string> | null = api.listNullableContainerString(['你好\ud800']);
const listNullableContainerStringAsync: Promise<Array<string> | null> = api.listNullableContainerStringAsync(['你好\ud800']);
void api.listNullableContainerString(null);
const listNullableBothString: Array<string | null> | null = api.listNullableBothString(['你好\ud800', null]);
const listNullableBothStringAsync: Promise<Array<string | null> | null> = api.listNullableBothStringAsync(['你好\ud800', null]);
void api.listNullableBothString(null);
const mapBool: Record<string, boolean> = api.mapBool({ first: true });
const mapBoolAsync: Promise<Record<string, boolean>> = api.mapBoolAsync({ first: true });
const mapNullableBool: Record<string, boolean | null> = api.mapNullableBool({ first: true, second: null });
const mapNullableBoolAsync: Promise<Record<string, boolean | null>> = api.mapNullableBoolAsync({ first: true, second: null });
const mapNullableContainerBool: Record<string, boolean> | null = api.mapNullableContainerBool({ first: true });
const mapNullableContainerBoolAsync: Promise<Record<string, boolean> | null> = api.mapNullableContainerBoolAsync({ first: true });
void api.mapNullableContainerBool(null);
const mapNullableBothBool: Record<string, boolean | null> | null = api.mapNullableBothBool({ first: true, second: null });
const mapNullableBothBoolAsync: Promise<Record<string, boolean | null> | null> = api.mapNullableBothBoolAsync({ first: true, second: null });
void api.mapNullableBothBool(null);
const mapInt: Record<string, number> = api.mapInt({ first: 42 });
const mapIntAsync: Promise<Record<string, number>> = api.mapIntAsync({ first: 42 });
const mapNullableInt: Record<string, number | null> = api.mapNullableInt({ first: 42, second: null });
const mapNullableIntAsync: Promise<Record<string, number | null>> = api.mapNullableIntAsync({ first: 42, second: null });
const mapNullableContainerInt: Record<string, number> | null = api.mapNullableContainerInt({ first: 42 });
const mapNullableContainerIntAsync: Promise<Record<string, number> | null> = api.mapNullableContainerIntAsync({ first: 42 });
void api.mapNullableContainerInt(null);
const mapNullableBothInt: Record<string, number | null> | null = api.mapNullableBothInt({ first: 42, second: null });
const mapNullableBothIntAsync: Promise<Record<string, number | null> | null> = api.mapNullableBothIntAsync({ first: 42, second: null });
void api.mapNullableBothInt(null);
const mapDouble: Record<string, number> = api.mapDouble({ first: Infinity });
const mapDoubleAsync: Promise<Record<string, number>> = api.mapDoubleAsync({ first: Infinity });
const mapNullableDouble: Record<string, number | null> = api.mapNullableDouble({ first: Infinity, second: null });
const mapNullableDoubleAsync: Promise<Record<string, number | null>> = api.mapNullableDoubleAsync({ first: Infinity, second: null });
const mapNullableContainerDouble: Record<string, number> | null = api.mapNullableContainerDouble({ first: Infinity });
const mapNullableContainerDoubleAsync: Promise<Record<string, number> | null> = api.mapNullableContainerDoubleAsync({ first: Infinity });
void api.mapNullableContainerDouble(null);
const mapNullableBothDouble: Record<string, number | null> | null = api.mapNullableBothDouble({ first: Infinity, second: null });
const mapNullableBothDoubleAsync: Promise<Record<string, number | null> | null> = api.mapNullableBothDoubleAsync({ first: Infinity, second: null });
void api.mapNullableBothDouble(null);
const mapString: Record<string, string> = api.mapString({ first: '你好\ud800' });
const mapStringAsync: Promise<Record<string, string>> = api.mapStringAsync({ first: '你好\ud800' });
const mapNullableString: Record<string, string | null> = api.mapNullableString({ first: '你好\ud800', second: null });
const mapNullableStringAsync: Promise<Record<string, string | null>> = api.mapNullableStringAsync({ first: '你好\ud800', second: null });
const mapNullableContainerString: Record<string, string> | null = api.mapNullableContainerString({ first: '你好\ud800' });
const mapNullableContainerStringAsync: Promise<Record<string, string> | null> = api.mapNullableContainerStringAsync({ first: '你好\ud800' });
void api.mapNullableContainerString(null);
const mapNullableBothString: Record<string, string | null> | null = api.mapNullableBothString({ first: '你好\ud800', second: null });
const mapNullableBothStringAsync: Promise<Record<string, string | null> | null> = api.mapNullableBothStringAsync({ first: '你好\ud800', second: null });
void api.mapNullableBothString(null);

const subpath: number[] = subpathListInt(Object.freeze([1, 2]));
const subpathAsync: Promise<Record<string, string | null> | null> = subpathMap(null);
const resolved: Array<number | null> | null = await subpathNullableList([1, null] as const);
const resolvedNumbers: number[] = await api.listIntAsync(readonlyNumbers);
listBool.push(false);
listInt[0] = 7;
listDouble.push(0);
listString[0] = 'mutable';
subpath.push(3);
resolvedNumbers[0] = 8;
resolvedNumbers.push(9);
if (resolved !== null) {
  resolved[0] = null;
  resolved.push(2);
}
void [exactInput, exactAsyncInput, exactNullableElements, exactNullableContainer, exactNullableBoth, exactOutput, exactAsyncOutput, subpathAsync];

// @ts-expect-error Scalar list leaves are exact.
api.listBool([1]);
// @ts-expect-error Integer collections use number rather than bigint.
api.listInt([1n]);
// @ts-expect-error Readonly arrays retain exact scalar element types.
api.listInt(['1'] as const);
// @ts-expect-error Freezing an array does not make its elements nullable.
subpathListInt(Object.freeze([null]));
// @ts-expect-error Nullable readonly elements still exclude undefined.
subpathNullableList([1, undefined] as const);
// @ts-expect-error Double leaves still require number.
api.listDouble([true]);
// @ts-expect-error Map double leaves do not accept numeric strings.
api.mapDouble({ value: '1' });
// @ts-expect-error Nonnullable list leaves reject null.
api.listString([null]);
// @ts-expect-error Nullable leaves do not make the container nullable.
api.listNullableInt(null);
// @ts-expect-error A nullable container does not make leaves nullable.
api.listNullableContainerString([null]);
// @ts-expect-error Undefined is not a nullable leaf.
api.listNullableBothInt([undefined]);
// @ts-expect-error Undefined is not a nullable container.
api.mapNullableBothString(undefined);
// @ts-expect-error Nested lists are outside the flat collection contract.
api.listInt([[1]]);
// @ts-expect-error Typed arrays are not dense JavaScript Array inputs.
api.listInt(new Uint8Array([1]));
// @ts-expect-error Native JS Map is not Record<string, number>.
api.mapInt(new Map([['x', 1]]));
// @ts-expect-error Map leaves are exact scalar types.
api.mapString({ value: 1 });
// @ts-expect-error Nonnullable map values reject null.
api.mapInt({ value: null });
// @ts-expect-error A nullable map container does not permit nullable values.
api.mapNullableContainerInt({ value: null });
// @ts-expect-error Nested records are outside the flat contract.
api.mapInt({ value: { nested: 1 } });
// @ts-expect-error Promise inputs are not materialized arrays.
api.listIntAsync(Promise.resolve([1]));
// @ts-expect-error Future outputs remain Promise values.
const synchronous: number[] = api.listIntAsync([1]);
// @ts-expect-error Resolved nullable containers require a null check.
const notNullable: Record<string, string | null> = await api.mapNullableBothStringAsync(null);
// @ts-expect-error Required positional arguments cannot be omitted.
api.listInt();
// @ts-expect-error Declarations check arity although raw Wasm ignores extras.
api.mapInt({ x: 1 }, { y: 2 });
