import {
  identityBool, identityInt, identityDouble, identityString, identityBytes,
  nullableString, incrementCounter, countedAdd, conditionalProfile, type Profile, fetch, URL, Error,
  wildcardSingle, wildcardRepeated, wildcardMixed,
} from './dist/module.wasm';

const bool: boolean = identityBool(true);
const int: number = identityInt(42);
const double: number = identityDouble(0.5);
const string: string = identityString('relative Wasm');
const bytes: Uint8Array = identityBytes(new Uint8Array([1, 2]));
const nullable: string | null = nullableString(null);
const voidResult: void = incrementCounter();
const sum: number = countedAdd(1, 2);
const profile: Profile = conditionalProfile({ count: 7, name: 'relative' });
type Equal<A, B> = (<T>() => T extends A ? 1 : 2) extends
  (<T>() => T extends B ? 1 : 2) ? true : false;
const exactProfile: Equal<Profile, { count: number; name: string }> = true;
const singleWildcard: number = wildcardSingle(1);
const repeatedWildcards: string = wildcardRepeated(1, 'ignored');
const mixedWildcards: string = wildcardMixed(1, 7, 'ignored', true, 9);
const exactSingleWildcard: Equal<typeof wildcardSingle, (value: number) => number> = true;
const exactRepeatedWildcards: Equal<typeof wildcardRepeated, (first: number, second: string) => string> = true;
const exactMixedWildcards: Equal<typeof wildcardMixed, (first: number, arg0: number, third: string, reserved: boolean, arg1: number) => string> = true;
const fetchResult: string = fetch('body');
const urlResult: number = URL();
const errorResult: string = Error();
void [bool, int, double, string, bytes, nullable, voidResult, sum, fetchResult, urlResult, errorResult];
void [profile, exactProfile];
void [singleWildcard, repeatedWildcards, mixedWildcards,
  exactSingleWildcard, exactRepeatedWildcards, exactMixedWildcards];

// @ts-expect-error Companion declarations must preserve the actual argument type.
identityInt('42');
// @ts-expect-error Byte arguments are Uint8Array, not plain arrays.
identityBytes([1, 2]);
// @ts-expect-error Nullable results cannot be assigned to a nonnullable value.
const wrong: string = nullableString(null);

// @ts-expect-error Relative Wasm declarations preserve both argument types.
countedAdd('1', 2);
// @ts-expect-error Relative Wasm declarations preserve the string record field.
conditionalProfile({ count: 7, name: 1 });

// @ts-expect-error Relative declarations require the ignored input too.
wildcardSingle();
// @ts-expect-error The ignored integer still uses number.
wildcardSingle('1');
// @ts-expect-error Repeated wildcards preserve positional arity.
wildcardRepeated(1);
// @ts-expect-error The second ignored input stays a string.
wildcardRepeated(1, 2);
// @ts-expect-error Mixed wildcards preserve the first ignored input type.
wildcardMixed('1', 7, 'ignored', true, 9);
// @ts-expect-error Mixed wildcard declarations preserve the third input type.
wildcardMixed(1, 7, 2, true, 9);
// @ts-expect-error The final named input remains required.
wildcardMixed(1, 7, 'ignored', true);
