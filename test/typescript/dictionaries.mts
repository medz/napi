import {Dictionary as UserDictionary, DictionaryHolder, RefBox,
  echoDictionary, nestedDictionary, referenceDictionary, bigintDictionary,
  optionalDictionary, namedDictionary, dictionaryAndMap, userDictionary}
  from '@napi/class-fixture';
import {echoDictionary as direct} from '@napi/class-fixture/module.wasm';
const value: {[key: string]: number} = echoDictionary({one: 1});
direct(value);
new DictionaryHolder(value, {initial: value}).replace(value);
DictionaryHolder.echo(value);
const ref = new RefBox(1);
const refs: {[key: string]: RefBox | null} = referenceDictionary({one: ref, empty: null});
nestedDictionary({first: [{$1: 1, owner: ref}, null], empty: null});
const wide: {[key: string]: {$1: bigint; $2: bigint | null}} = bigintDictionary({one: {$1: 1n, $2: null}});
optionalDictionary(); optionalDictionary(undefined); optionalDictionary(null); namedDictionary({value: null});
const custom: {[key: string]: UserDictionary} = userDictionary({one: new UserDictionary(3)});
const mixed: {$1: {[key: string]: number}; $2: Map<string, number>} = dictionaryAndMap(value, new Map());
// @ts-expect-error a Dictionary is an object, not a Map.
echoDictionary(new Map([['one', 1]]));
// @ts-expect-error strict value type.
echoDictionary({one: 'wrong'});
// @ts-expect-error bigint mapping covers nested int leaves.
bigintDictionary({one: {$1: 1, $2: 2n}});
// @ts-expect-error required named argument cannot be absent.
namedDictionary({});
// @ts-expect-error required nullable is not undefined.
namedDictionary({value: undefined});
void [refs, wide, custom, mixed];
