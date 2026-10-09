import { echoUser, echoUserAsync, echoNullableAlias, echoChainAsync, echoInline, echoInlineAsync, echoMixed, echoSpecialAsync, echoPart, User as userFunction } from './dist/module.wasm';
import type { User, UserAlias, NullableUser, MaybeUserAlias, Mixed, SpecialFields, PartValue } from './dist/module.wasm';

const input: User = { name: 'relative', age: 20, active: null };
const output: UserAlias = echoUser(input);
const pending: Promise<User | null> = echoUserAsync(input);
const nullable: NullableUser = echoNullableAlias(null);
const chained: MaybeUserAlias = await echoChainAsync(null);
const valueFunction: (value: User) => User = userFunction;
const valueOutput: User = valueFunction(input);
const inline: { label: string; count: number; flag: boolean | null; score: number } = echoInline({ label: 'x', count: 1, flag: null, score: -0 });
const inlinePending: Promise<typeof inline | null> = echoInlineAsync(null);
const mixed: Mixed = echoMixed({ flag: true, count: 2, value: NaN, text: '\ud800', maybeFlag: null, maybeCount: null, maybeValue: null, maybeText: null });
const special: SpecialFields = await echoSpecialAsync({ constructor: 'own', prototype: 'plain', then: 'scalar', $value: -0 });
const part: PartValue = echoPart({ code: 7, message: 'part' });
output.age = 21;
void [pending, nullable, chained, valueOutput, inlinePending, mixed, special, part];

// @ts-expect-error Relative declarations preserve required nullable fields.
echoUser({ name: 'relative', age: 20 });
// @ts-expect-error Relative declarations reject undefined containers.
echoUserAsync(undefined);
// @ts-expect-error Nullable alias fields are still required.
echoNullableAlias({ name: 'relative', age: 20 });
// @ts-expect-error Alias chains retain nullability, rather than making it void.
const nonnullable: User = await echoChainAsync(input);
// @ts-expect-error Future conversion retains its Promise type.
const synchronous: User | null = echoUserAsync(input);
// @ts-expect-error Inline named fields remain strict.
echoInline({ label: 'x', count: '1', flag: null, score: 0 });
// @ts-expect-error Scalar then fields do not become callbacks.
echoSpecialAsync({ constructor: 'x', prototype: 'y', then() {}, $value: 0 });
// @ts-expect-error Part-defined record shapes are precise.
echoPart({ code: 7, message: false });
