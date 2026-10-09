import { normalizeUsers, totalAge, echoUsers, echoNullableBothUsersAsync, echoNullableAlias, echoChain, echoInlineAsync, echoSpecialAsync, echoPart } from './dist/module.wasm';
import type { User, UserAlias, MaybeUserAlias, SpecialFields, BatchPart } from './dist/module.wasm';

const user: User = { name: 'relative', age: 20, active: null };
const normalized: User[] = normalizeUsers([user]);
const age: number = totalAge(normalized);
const chained: UserAlias[] = echoChain(normalized);
const nullableAlias: MaybeUserAlias[] = echoNullableAlias([user, null]);
const pending: Promise<Array<User | null> | null> = echoNullableBothUsersAsync(null);
const completed: Array<User | null> | null = await echoNullableBothUsersAsync([user, null]);
const inline: Array<{ label: string; count: number; flag: boolean | null; score: number } | null> | null = await echoInlineAsync([{ label: 'inline', count: 1, flag: null, score: -0 }, null]);
const special: SpecialFields[] = await echoSpecialAsync([{ constructor: 'own', prototype: 'plain', then: 'scalar', $value: -0 }]);
const part: Array<BatchPart | null> | null = echoPart([{ code: 7, message: 'part' }, null]);
void [age, chained, nullableAlias, pending, completed, inline, special, part];

// @ts-expect-error Relative declarations retain required nullable fields.
echoUsers([{ name: 'relative', age: 20 }]);
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
