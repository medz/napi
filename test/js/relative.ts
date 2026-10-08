import {
  identityBool, identityInt, identityDouble, identityString, identityBytes,
  nullableString, incrementCounter, fetch, URL, Error,
} from './dist/module.wasm';

const bool: boolean = identityBool(true);
const int: number = identityInt(42);
const double: number = identityDouble(0.5);
const string: string = identityString('relative Wasm');
const bytes: Uint8Array = identityBytes(new Uint8Array([1, 2]));
const nullable: string | null = nullableString(null);
const voidResult: void = incrementCounter();
const fetchResult: string = fetch('body');
const urlResult: number = URL();
const errorResult: string = Error();
void [bool, int, double, string, bytes, nullable, voidResult, fetchResult, urlResult, errorResult];

// @ts-expect-error Companion declarations must preserve the actual argument type.
identityInt('42');
// @ts-expect-error Byte arguments are Uint8Array, not plain arrays.
identityBytes([1, 2]);
// @ts-expect-error Nullable results cannot be assigned to a nonnullable value.
const wrong: string = nullableString(null);
