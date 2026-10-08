import {
  listInt, listNullableBothString, listNullableBothIntAsync,
  mapBool, mapNullableBothStringAsync,
} from './dist/module.wasm';

const numbers: number[] = listInt([1, 2]);
const strings: Array<string | null> | null = listNullableBothString(['你好', null]);
const bools: Record<string, boolean> = mapBool({ yes: true });
const pending: Promise<Array<number | null> | null> = listNullableBothIntAsync(null);
const completed: Record<string, string | null> | null = await mapNullableBothStringAsync({ greeting: 'hello', empty: null });
void [numbers, strings, bools, pending, completed];

// @ts-expect-error Companion declarations preserve flat leaf types.
listInt([[1]]);
// @ts-expect-error Future completion is not a synchronous return value.
const wrongPromise: number[] | null = listNullableBothIntAsync([1]);
// @ts-expect-error Nullability excludes undefined.
listNullableBothString(undefined);
// @ts-expect-error Map values preserve their nullable scalar type.
mapNullableBothStringAsync({ value: false });
