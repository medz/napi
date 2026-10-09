import * as api from '@napi/batch';
import { normalizeUsers as subpathNormalize, echoNullableBothUsersAsync as subpathAsync } from '@napi/batch/module.wasm';
import type { User, UserAlias, MaybeUserAlias, Mixed, SpecialFields, BatchPart } from '@napi/batch';
import type { User as SubpathUser } from '@napi/batch/module.wasm';

// These aliases are reachable only through List completion/parameter values.
const user: User = { name: ' Dart ', age: 20, active: null };
const users: User[] = [user];
const output: User[] = api.echoUsers(users);
const normalized: User[] = api.normalizeUsers(users);
const normalizedPending: Promise<User[]> = api.normalizeUsersAsync(users);
const ages: number = api.totalAge(users);
const agesPending: Promise<number> = api.totalAgeAsync(users);
const regularPending: Promise<User[]> = api.echoUsersAsync(users);
const nullableElements: Array<User | null> = api.echoNullableUsers([user, null]);
const nullableElementsPending: Promise<Array<User | null>> = api.echoNullableUsersAsync([null]);
const nullableContainer: User[] | null = api.echoNullableContainerUsers(null);
const nullableContainerPending: Promise<User[] | null> = api.echoNullableContainerUsersAsync(users);
const nullableBoth: Array<User | null> | null = api.echoNullableBothUsers([user, null]);
const nullableBothPending: Promise<Array<User | null> | null> = api.echoNullableBothUsersAsync(null);
const completed: Array<User | null> | null = await api.echoNullableBothUsersAsync([user, null]);
const nullableAlias: MaybeUserAlias[] = api.echoNullableAlias([user, null]);
const nullableAliasPending: Promise<MaybeUserAlias[]> = api.echoNullableAliasAsync([null]);
const chained: UserAlias[] = api.echoChain(users);
const chainedPending: Promise<UserAlias[]> = api.echoChainAsync(users);
const subpath: SubpathUser[] = subpathNormalize(users);
const subpathPending: Promise<Array<SubpathUser | null> | null> = subpathAsync(null);
const moreFields = [{ ...user, ignored: true }];
const structural: UserAlias[] = api.echoUsers(moreFields);
const readonlyFields: Array<Readonly<User>> = [user];
const readonlyAccepted: User[] = api.echoUsers(readonlyFields);
class UserData {
  name = 'Dart';
  age = 20;
  active: boolean | null = null;
}
// TS describes structural fields, not runtime prototype/descriptor checks.
const classShape: User[] = api.echoUsers([new UserData()]);
output[0].name = 'mutable JS result';
output.push(user);

const mixed: Mixed = { flag: true, count: 2, value: NaN, text: '\ud800', maybeFlag: null, maybeCount: null, maybeValue: -0, maybeText: null };
const mixedOutput: Mixed[] = api.echoMixed([mixed]);
const mixedPending: Promise<Mixed[]> = api.echoMixedAsync([mixed]);
const special: SpecialFields = { constructor: 'own', prototype: '\ud800', then: 'scalar', $value: -0 };
const specialOutput: SpecialFields[] = api.echoSpecial([special]);
const specialPending: Promise<SpecialFields[]> = api.echoSpecialAsync([special]);
type Inline = { label: string; count: number; flag: boolean | null; score: number };
const inline: Inline = { label: 'inline', count: 1, flag: null, score: Infinity };
const inlineOutput: Array<Inline | null> | null = api.echoInline([inline, null]);
const inlinePending: Promise<Array<Inline | null> | null> = api.echoInlineAsync(null);
const part: BatchPart = { code: 7, message: 'part' };
const partOutput: Array<BatchPart | null> | null = api.echoPart([part, null]);
const partPending: Promise<Array<BatchPart | null> | null> = api.echoPartAsync(null);
const tracked: User[] = api.tracked(users, users);
const trackedPending: Promise<User[]> = api.trackedAsync(users, users);
const stored: User[] = api.readStored();
const storedPending: Promise<User[]> = api.readStoredAsync();
const changed: void = api.changeStored();
const repeated: User[] = api.repeatFirst(users);
const repeatedPending: Promise<User[]> = api.repeatFirstAsync(users);
const unsafe: User[] = api.unsafeUsers();
const unsafePending: Promise<User[]> = api.unsafeUsersAsync();
const unsafeMixed: Mixed[] = api.unsafeMixed();
const unsafeMixedPending: Promise<Mixed[]> = api.unsafeMixedAsync();
const invalidLength: User[] = api.invalidLengthUsers(-1);
const invalidLengthPending: Promise<User[]> = api.invalidLengthUsersAsync(0x100000000);
const invalidIndexReads: number = api.invalidIndexReads();
void [invalidLength, invalidLengthPending, invalidIndexReads];
void [normalized, normalizedPending, ages, agesPending, regularPending, nullableElements, nullableElementsPending, nullableContainer, nullableContainerPending, nullableBoth, nullableBothPending, completed, nullableAlias, nullableAliasPending, chained, chainedPending, subpath, subpathPending, structural, readonlyAccepted, classShape, mixedOutput, mixedPending, specialOutput, specialPending, inlineOutput, inlinePending, partOutput, partPending, tracked, trackedPending, stored, storedPending, changed, repeated, repeatedPending, unsafe, unsafePending, unsafeMixed, unsafeMixedPending];

// @ts-expect-error Nullable record fields remain required inside lists.
api.echoUsers([{ name: 'Dart', age: 20 }]);
// @ts-expect-error Named scalar fields retain their types.
api.echoUsers([{ ...user, age: '20' }]);
// @ts-expect-error A nullable field cannot be undefined.
api.echoUsers([{ ...user, active: undefined }]);
// @ts-expect-error A nonnullable container rejects null.
api.echoNullableUsers(null);
// @ts-expect-error A nullable container does not make elements nullable.
api.echoNullableContainerUsers([null]);
// @ts-expect-error A nullable element does not permit undefined.
api.echoNullableBothUsers([undefined]);
// @ts-expect-error A nullable container does not permit undefined.
api.echoNullableBothUsers(undefined);
// @ts-expect-error Nullable typedef RHS is still a required-field record.
api.echoNullableAlias([{ name: 'Dart', age: 20 }]);
// @ts-expect-error Nullable alias elements exclude undefined.
api.echoNullableAlias([undefined]);
// @ts-expect-error A nonnullable alias chain excludes null elements.
api.echoChain([null]);
// @ts-expect-error The contract permits a single List layer.
api.echoUsers([[user]]);
// @ts-expect-error Native typed arrays are not Arrays of records.
api.echoUsers(new Uint8Array([1]));
// @ts-expect-error Promises are not materialized input arrays.
api.echoUsersAsync(Promise.resolve(users));
// @ts-expect-error Native JS Map is not an Array of records.
api.echoUsers(new Map([['user', user]]));
// @ts-expect-error Integer fields use numbers rather than bigint.
api.echoUsers([{ ...user, age: 20n }]);
// @ts-expect-error Fresh literals keep normal excess-property checking.
api.echoUsers([{ ...user, ignored: true }]);
// @ts-expect-error Mixed nullable fields remain independently strict.
api.echoMixed([{ ...mixed, maybeFlag: 1 }]);
// @ts-expect-error Mixed nonnullable fields reject null.
api.echoMixed([{ ...mixed, count: null }]);
// @ts-expect-error then remains a scalar, not a callback.
api.echoSpecial([{ ...special, then() {} }]);
// @ts-expect-error Dollar-named record fields retain their scalar type.
api.echoSpecial([{ ...special, $value: false }]);
// @ts-expect-error Part-defined record fields remain required.
api.echoPart([{ code: 7 }]);
// @ts-expect-error Inline named fields remain strict.
api.echoInline([{ ...inline, score: '0' }]);
// @ts-expect-error Futures return Promises rather than synchronous arrays.
const synchronous: User[] = api.echoUsersAsync(users);
// @ts-expect-error Nullable container completion requires a null check.
const nonnullableContainer: User[] = await api.echoNullableContainerUsersAsync(users);
// @ts-expect-error Nullable elements require an element null check.
const nonnullableElements: User[] = api.echoNullableUsers([user]);
// @ts-expect-error Nullable alias RHS survives list completion.
const nonnullableAlias: User[] = await api.echoNullableAliasAsync(users);
// @ts-expect-error A type-only alias has no runtime Wasm export.
const runtimeType = api.User;
// @ts-expect-error Required positional arguments cannot be omitted.
api.echoUsers();
// @ts-expect-error Declarations check arity even though raw Wasm ignores extras.
api.echoUsers(users, users);
