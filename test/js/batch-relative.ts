import { normalizeUsers, totalAge, echoUsers, echoNullableBothUsersAsync, echoNullableAlias, echoChain, echoInlineAsync, echoSpecialAsync, echoPart, echoReadonlyArrays } from './dist/module.wasm';
import type { User, UserAlias, MaybeUserAlias, SpecialFields, BatchPart, ReadonlyArray } from './dist/module.wasm';

type Equal<X, Y> = (<T>() => T extends X ? 1 : 2) extends (<T>() => T extends Y ? 1 : 2) ? true : false;
const exactInput: Equal<Parameters<typeof echoUsers>[0], readonly User[]> = true;
const exactNullableInput: Equal<Parameters<typeof echoNullableBothUsersAsync>[0], readonly (User | null)[] | null> = true;
const exactReadonlyArrayInput: Equal<Parameters<typeof echoReadonlyArrays>[0], readonly ReadonlyArray[]> = true;
const exactOutput: Equal<ReturnType<typeof echoReadonlyArrays>, ReadonlyArray[]> = true;
const exactAsyncOutput: Equal<ReturnType<typeof echoNullableBothUsersAsync>, Promise<Array<User | null> | null>> = true;

const user: User = { name: 'relative', age: 20, active: null };
const users: readonly User[] = [user];
const normalized: User[] = normalizeUsers(users);
const age: number = totalAge(normalized);
const chained: UserAlias[] = echoChain(normalized);
const nullableAlias: MaybeUserAlias[] = echoNullableAlias([user, null] as const);
const pending: Promise<Array<User | null> | null> = echoNullableBothUsersAsync(null);
const completed: Array<User | null> | null = await echoNullableBothUsersAsync(Object.freeze([Object.freeze(user), null]));
const inline: Array<{ label: string; count: number; flag: boolean | null; score: number } | null> | null = await echoInlineAsync([{ label: 'inline', count: 1, flag: null, score: -0 }, null] as const);
const special: SpecialFields[] = await echoSpecialAsync([{ constructor: 'own', prototype: 'plain', then: 'scalar', $value: -0 }]);
const part: Array<BatchPart | null> | null = echoPart([{ code: 7, message: 'part' }, null]);
const alias: ReadonlyArray = { count: 1 };
const aliasOutput: ReadonlyArray[] = echoReadonlyArrays(Object.freeze([alias]));
normalized[0].name = 'mutable';
normalized.push(user);
if (completed !== null) {
  if (completed[0] !== null) completed[0].age = 21;
  completed.push(null);
}
if (inline !== null) {
  if (inline[0] !== null) inline[0].label = 'mutable';
  inline.push(null);
}
aliasOutput[0].count = 2;
aliasOutput.push({ count: 3 });
void [exactInput, exactNullableInput, exactReadonlyArrayInput, exactOutput, exactAsyncOutput, age, chained, nullableAlias, pending, special, part];

// @ts-expect-error Relative declarations retain required nullable fields.
echoUsers([{ name: 'relative', age: 20 }]);
// @ts-expect-error Readonly rows retain required nullable fields.
echoUsers([{ name: 'relative', age: 20 }] as const);
// @ts-expect-error Frozen record arrays retain scalar fields.
echoUsers(Object.freeze([{ ...user, age: false }]));
// @ts-expect-error Readonly nullable rows exclude undefined.
echoNullableBothUsersAsync([user, undefined] as const);
// @ts-expect-error ReadonlyArray is a record alias, not an untyped array.
echoReadonlyArrays([{ count: false }] as const);
// @ts-expect-error A nullable element is not undefined.
echoNullableBothUsersAsync([undefined]);
// @ts-expect-error A nullable container is not undefined.
echoNullableBothUsersAsync(undefined);
// @ts-expect-error Nullable typedef RHS is preserved for each element.
const nonnullableAlias: User[] = echoNullableAlias([user]);
// @ts-expect-error Nullable containers and elements survive Promise conversion.
const synchronous: User[] = echoNullableBothUsersAsync([user]);
// @ts-expect-error The API permits one List layer.
echoUsers([[user]]);
// @ts-expect-error Scalar then is not a function.
echoSpecialAsync([{ constructor: 'x', prototype: 'y', then() {}, $value: 0 }]);
// @ts-expect-error Part type fields retain their scalar types.
echoPart([{ code: 7, message: false }]);
