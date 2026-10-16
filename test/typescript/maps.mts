import {Map as UserMap, MapHolder, MapKey, RefBox, echoMap, nestedMap,
  referenceMap, recordKeyMap, bigintMap, optionalMap, namedMap, userMap,
  equalKeyMap} from '@napi/class-fixture';
import {echoMap as direct} from '@napi/class-fixture/module.wasm';
const value: Map<string, number> = echoMap(new Map([['one', 1]]));
direct(value);
new MapHolder(value, {initial: value}).replace(value);
MapHolder.echo(value);
const ref = new RefBox(1);
const refs: Map<RefBox | null, RefBox | null> = referenceMap(new Map([[ref, ref]]));
nestedMap(new Map([['row', [{$1: 1, owner: ref}, null]]]));
recordKeyMap(new Map([[{$1: 1}, 'one']]));
const wide: Map<bigint, bigint | null> = bigintMap(new Map([[1n, null]]));
optionalMap(); optionalMap(undefined); optionalMap(null); namedMap({value: null});
const key = new UserMap(3);
const custom: Map<UserMap, UserMap> = userMap(new Map([[key, key]]));
equalKeyMap(new Map([[new MapKey(1), 2]]));
// @ts-expect-error Maps never accept dictionaries.
echoMap({one: 1});
// @ts-expect-error wrong Map key.
echoMap(new Map([[1, 2]]));
// @ts-expect-error bigint mapping covers keys too.
bigintMap(new Map([[1, 2n]]));
// @ts-expect-error required named argument cannot be absent.
namedMap({});
// @ts-expect-error required nullable is not undefined.
namedMap({value: undefined});
void [refs, wide, custom];
