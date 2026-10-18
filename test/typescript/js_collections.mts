import * as api from '@napi/js-collections-fixture';
import * as direct from '@napi/js-collections-fixture/BACKEND';
import * as external from '@napi/js-collections-external';
const array: number[] = api.remember([1]);
const same: number[] = direct.remember(external.remember(array));
const map: Map<string, number | null> = api.rememberMap(new Map([['a', 1], ['b', null]]));
const big: bigint[] = api.int64([1n]);
const wide: bigint[] = api.bigints([1n << 100n]);
const maybe: number[] | null = api.optional();
api.optional(undefined); api.optional(null); api.named(); api.named({value: array});
const nullable: (number | null)[] = api.nullable([null, 1]);
const holder = new api.Holder(array); holder.value = array;
const promise: Promise<number[]> = api.later(array);
const stream: AsyncIterableIterator<number[], undefined, undefined> = api.events(array);
const mapPromise: Promise<Map<string, number | null>> = api.laterMap(map);
const owner = new api.Owner(); const owned: Promise<number[]> = owner.retain(array);
// @ts-expect-error Required input cannot be omitted.
api.remember();
// @ts-expect-error Non-null input.
api.remember(null);
// @ts-expect-error Element type is strict.
api.remember(['x']);
// @ts-expect-error No implicit undefined element.
api.nullable([undefined]);
// @ts-expect-error bigint policy uses bigint.
api.int64([1]);
// @ts-expect-error Map keys are strings.
api.rememberMap(new Map([[1, 1]]));
// @ts-expect-error A collection handle is the original Array, not a facade.
array.get(0);
void [array, same, map, big, wide, maybe, nullable, holder, promise, stream, mapPromise, owned];
