import * as api from '@napi/collections';
import { listInt as subpathListInt, mapNullableBothStringAsync as subpathMap } from '@napi/collections/module.wasm';

const listBool: Array<boolean> = api.listBool([true]);
const listBoolAsync: Promise<Array<boolean>> = api.listBoolAsync([true]);
const listNullableBool: Array<boolean | null> = api.listNullableBool([true, null]);
const listNullableBoolAsync: Promise<Array<boolean | null>> = api.listNullableBoolAsync([true, null]);
const listNullableContainerBool: Array<boolean> | null = api.listNullableContainerBool([true]);
const listNullableContainerBoolAsync: Promise<Array<boolean> | null> = api.listNullableContainerBoolAsync([true]);
void api.listNullableContainerBool(null);
const listNullableBothBool: Array<boolean | null> | null = api.listNullableBothBool([true, null]);
const listNullableBothBoolAsync: Promise<Array<boolean | null> | null> = api.listNullableBothBoolAsync([true, null]);
void api.listNullableBothBool(null);
const listInt: Array<number> = api.listInt([42]);
const listIntAsync: Promise<Array<number>> = api.listIntAsync([42]);
const listNullableInt: Array<number | null> = api.listNullableInt([42, null]);
const listNullableIntAsync: Promise<Array<number | null>> = api.listNullableIntAsync([42, null]);
const listNullableContainerInt: Array<number> | null = api.listNullableContainerInt([42]);
const listNullableContainerIntAsync: Promise<Array<number> | null> = api.listNullableContainerIntAsync([42]);
void api.listNullableContainerInt(null);
const listNullableBothInt: Array<number | null> | null = api.listNullableBothInt([42, null]);
const listNullableBothIntAsync: Promise<Array<number | null> | null> = api.listNullableBothIntAsync([42, null]);
void api.listNullableBothInt(null);
const listDouble: Array<number> = api.listDouble([Infinity]);
const listDoubleAsync: Promise<Array<number>> = api.listDoubleAsync([Infinity]);
const listNullableDouble: Array<number | null> = api.listNullableDouble([Infinity, null]);
const listNullableDoubleAsync: Promise<Array<number | null>> = api.listNullableDoubleAsync([Infinity, null]);
const listNullableContainerDouble: Array<number> | null = api.listNullableContainerDouble([Infinity]);
const listNullableContainerDoubleAsync: Promise<Array<number> | null> = api.listNullableContainerDoubleAsync([Infinity]);
void api.listNullableContainerDouble(null);
const listNullableBothDouble: Array<number | null> | null = api.listNullableBothDouble([Infinity, null]);
const listNullableBothDoubleAsync: Promise<Array<number | null> | null> = api.listNullableBothDoubleAsync([Infinity, null]);
void api.listNullableBothDouble(null);
const listString: Array<string> = api.listString(['你好\ud800']);
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

const subpath: number[] = subpathListInt([1, 2]);
const subpathAsync: Promise<Record<string, string | null> | null> = subpathMap(null);
const resolved: Array<number | null> | null = await api.listNullableBothIntAsync([1, null]);
void [subpath, subpathAsync, resolved];

// @ts-expect-error Scalar list leaves are exact.
api.listBool([1]);
// @ts-expect-error Integer collections use number rather than bigint.
api.listInt([1n]);
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
