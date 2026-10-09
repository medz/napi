import {
  identityBool, identityInt, identityDouble, identityString, identityBytes,
  nullableString, incrementCounter, countedAdd, conditionalProfile, type Profile, fetch, URL, Error,
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
const fetchResult: string = fetch('body');
const urlResult: number = URL();
const errorResult: string = Error();
void [bool, int, double, string, bytes, nullable, voidResult, sum, fetchResult, urlResult, errorResult];
void [profile, exactProfile];

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
