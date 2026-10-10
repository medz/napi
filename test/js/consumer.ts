import {
  identityBool, identityInt, identityDouble, identityString, identityBytes,
  nullableBool, nullableInt, nullableDouble, nullableString, nullableBytes,
  incrementCounter, counter, countedAdd, conditionalProfile, type Profile, oversizedInt, throwError,
  readFile, response, instantiate, $napiReadFile, fetch, URL, Error,
  wildcardSingle, wildcardRepeated, wildcardMixed,
} from '@napi/integration';
import {
  identityInt as subpathInt, conditionalProfile as subpathProfile, type Profile as SubpathProfile,
  wildcardMixed as subpathWildcard,
} from '@napi/integration/module.wasm';

const bool: boolean = identityBool(true);
const int: number = identityInt(12);
const double: number = identityDouble(0.125);
const string: string = identityString('你好');
const bytes: Uint8Array = identityBytes(new Uint8Array([1, 2]));
const maybeBool: boolean | null = nullableBool(null);
const maybeInt: number | null = nullableInt(null);
const maybeDouble: number | null = nullableDouble(null);
const maybeString: string | null = nullableString(null);
const maybeBytes: Uint8Array | null = nullableBytes(null);
const voidResult: void = incrementCounter();
const count: number = counter();
const sum: number = countedAdd(1, 2);
const profile: Profile = conditionalProfile({ count: 7, name: 'root' });
const subpathProfileResult: SubpathProfile = subpathProfile(profile);
type Equal<A, B> = (<T>() => T extends A ? 1 : 2) extends
  (<T>() => T extends B ? 1 : 2) ? true : false;
const exactProfile: Equal<Profile, { count: number; name: string }> = true;
const exactSubpathProfile: Equal<SubpathProfile, Profile> = true;
const singleWildcard: number = wildcardSingle(1);
const repeatedWildcards: string = wildcardRepeated(1, 'ignored');
const mixedWildcards: string = wildcardMixed(1, 7, 'ignored', true, 9);
const subpathWildcards: string = subpathWildcard(1, 9, 'ignored', false, 7);
const exactSingleWildcard: Equal<typeof wildcardSingle, (value: number) => number> = true;
const exactRepeatedWildcards: Equal<typeof wildcardRepeated, (first: number, second: string) => string> = true;
const exactMixedWildcards: Equal<typeof wildcardMixed, (first: number, arg0: number, third: string, reserved: boolean, arg1: number) => string> = true;
const exactSubpathWildcards: Equal<typeof subpathWildcard, typeof wildcardMixed> = true;
const unsafe: number = oversizedInt();
const exception: number = throwError('error');
const readFileResult: string = readFile('name');
const responseResult: string = response('body');
const instantiateResult: number = instantiate(9);
const dollarResult: string = $napiReadFile('name');
const fetchResult: string = fetch('body');
const urlResult: number = URL();
const errorResult: string = Error();
const subpathResult: number = subpathInt(42);
void [bool, int, double, string, bytes, maybeBool, maybeInt, maybeDouble, maybeString, maybeBytes, voidResult, count, sum, unsafe, exception, readFileResult, responseResult, instantiateResult, dollarResult, fetchResult, urlResult, errorResult, subpathResult];
void [profile, subpathProfileResult, exactProfile, exactSubpathProfile];
void [singleWildcard, repeatedWildcards, mixedWildcards, subpathWildcards,
  exactSingleWildcard, exactRepeatedWildcards, exactMixedWildcards, exactSubpathWildcards];

// @ts-expect-error Wrong input type must not be accepted by generated declarations.
identityBool(1);
// @ts-expect-error Integer exports use number, never bigint.
identityInt(1n);
// @ts-expect-error Strings are not numbers.
identityDouble('1');
// @ts-expect-error Null is reserved for explicitly nullable arguments.
identityString(null);
// @ts-expect-error Arrays are not byte arrays.
identityBytes([1, 2]);
// @ts-expect-error Required positional arguments cannot be omitted.
identityInt();
// @ts-expect-error TypeScript checks the declared signature even when Wasm ignores extra arguments.
identityInt(1, 2);
// @ts-expect-error Undefined is not null.
nullableInt(undefined);
// @ts-expect-error Nullable results cannot be assigned to a nonnullable value.
const nonnullable: string = nullableString('value');

// @ts-expect-error Two-argument exports preserve the required second argument.
countedAdd(1);
// @ts-expect-error Both add arguments must be numbers.
countedAdd(1, '2');
// @ts-expect-error The conditional record count field is a number.
conditionalProfile({ count: '7', name: 'root' });
// @ts-expect-error The subpath record requires its string field.
subpathProfile({ count: 7 });

// @ts-expect-error A wildcard remains a required positional input.
wildcardSingle();
// @ts-expect-error An ignored integer still requires number.
wildcardSingle('1');
// @ts-expect-error Repeated wildcards retain their required second input.
wildcardRepeated(1);
// @ts-expect-error The second ignored input is a string.
wildcardRepeated(1, 2);
// @ts-expect-error Mixed wildcard bindings preserve the third input type.
wildcardMixed(1, 7, 2, true, 9);
// @ts-expect-error Reserved-name fallback preserves the fourth input type.
wildcardMixed(1, 7, 'ignored', 'true', 9);
// @ts-expect-error Subpath declarations retain the final required named input.
subpathWildcard(1, 7, 'ignored', true);
