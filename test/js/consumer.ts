import {
  identityBool, identityInt, identityDouble, identityString, identityBytes,
  nullableBool, nullableInt, nullableDouble, nullableString, nullableBytes,
  incrementCounter, counter, countedAdd, oversizedInt, throwError,
  readFile, response, instantiate, $napiReadFile, fetch, URL, Error,
} from '@napi/integration';
import { identityInt as subpathInt } from '@napi/integration/module.wasm';

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
