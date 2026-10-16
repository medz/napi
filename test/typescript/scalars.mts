import {
  add, calls, scalarCalls, echo, fail, evaluate, argumentCount,
  echoBool, negate, echoString, reverseString, stringLength, stringCodeUnitAt,
  echoDouble, reciprocal, echoBigInt, addBigInt,
  nullableBool, nullableString, nullableDouble, nullableInt, nullableBigInt,
  echoWideInt, addWideInt, nullableWideInt, chooseWideInt, promoteWideInt,
  wideIntToDouble, unsafeIntResult, unsafeNullableIntResult,
} from './module.wasm';

const result: number = add(1, 2);
const count: number = calls() + scalarCalls();
echo(result + count);
fail(1);
// Declaration parameter names eval/arguments are valid in TypeScript 7.
const evaluated: number = evaluate(result);
const argumentResult: number = argumentCount(evaluated);
echo(argumentResult);

const booleanResult: boolean = echoBool(negate(true));
const stringResult: string = echoString(reverseString('🙂'));
const length: number = stringLength(stringResult);
const codeUnit: number = stringCodeUnitAt(stringResult, length - 1);
const doubleResult: number = echoDouble(reciprocal(-0));
const bigResult: bigint = echoBigInt(addBigInt(1n << 521n, -1n));
const wideResult: bigint = echoWideInt(addWideInt(1n << 53n, 1n));
const promoted: bigint = promoteWideInt(wideResult);
const convertedDouble: number = wideIntToDouble(wideResult);
const optionalBoolean: boolean | null = nullableBool(booleanResult);
const optionalString: string | null = nullableString(stringResult);
const optionalDouble: number | null = nullableDouble(doubleResult);
const optionalInt: number | null = nullableInt(codeUnit);
const optionalBigInt: bigint | null = nullableBigInt(bigResult);
const optionalWideInt: bigint | null = nullableWideInt(wideResult);
const chosen: bigint | null = chooseWideInt(true, wideResult, null, 'pick', 1.5);
const checkedIntResult: number = unsafeIntResult(false);
const checkedOptionalInt: number | null = unsafeNullableIntResult(false);
nullableBool(null);
nullableString(null);
nullableDouble(null);
nullableInt(null);
nullableBigInt(null);
nullableWideInt(null);

// Verify exact representations, nullability and requiredness, not just assignability.
type Equal<A, B> = (<T>() => T extends A ? 1 : 2) extends (<T>() => T extends B ? 1 : 2) ? true : false;
type Assert<T extends true> = T;
type ScalarSignatures = [
  Assert<Equal<typeof echo, (value: number) => number>>,
  Assert<Equal<typeof echoBool, (value: boolean) => boolean>>,
  Assert<Equal<typeof echoString, (value: string) => string>>,
  Assert<Equal<typeof echoDouble, (value: number) => number>>,
  Assert<Equal<typeof echoBigInt, (value: bigint) => bigint>>,
  Assert<Equal<typeof echoWideInt, (value: bigint) => bigint>>,
  Assert<Equal<typeof nullableBool, (value: boolean | null) => boolean | null>>,
  Assert<Equal<typeof nullableString, (value: string | null) => string | null>>,
  Assert<Equal<typeof nullableDouble, (value: number | null) => number | null>>,
  Assert<Equal<typeof nullableInt, (value: number | null) => number | null>>,
  Assert<Equal<typeof nullableBigInt, (value: bigint | null) => bigint | null>>,
  Assert<Equal<typeof nullableWideInt, (value: bigint | null) => bigint | null>>,
  Assert<Equal<typeof chooseWideInt, (first: boolean, left: bigint | null, right: bigint | null, label: string, score: number) => bigint | null>>,
  Assert<Equal<typeof promoteWideInt, (value: bigint) => bigint>>,
  Assert<Equal<typeof wideIntToDouble, (value: bigint) => number>>,
];

// @ts-expect-error required argument is missing
add(1);
// @ts-expect-error unsafe implicit coercion is not the API
add('1', 2);
// @ts-expect-error number representation is fixed
add(1n, 2n);
// @ts-expect-error nonnullable inputs reject null
add(null, 2);
// @ts-expect-error explicit undefined is invalid for required scalar
add(undefined, 2);
// @ts-expect-error native function export is not a constructor
new add(1, 2);
// @ts-expect-error booleans are not numbers
echoBool(1);
// @ts-expect-error strings do not accept objects or coerce
echoString({ toString: () => 'x' });
// @ts-expect-error double does not accept bigint
echoDouble(1n);
// @ts-expect-error Dart BigInt always uses JavaScript bigint
echoBigInt(1);
// @ts-expect-error bigint int policy does not accept number
echoWideInt(1);
// @ts-expect-error bigint int results are not numbers
const wrongWideResult: number = echoWideInt(1n);
// @ts-expect-error default int results are not bigint
const wrongIntResult: bigint = echo(1);
// @ts-expect-error double results are not bigint even under bigint policy
const wrongDoubleResult: bigint = wideIntToDouble(1n);
// @ts-expect-error mixed signature retains boolean input
chooseWideInt(1n, 1n, 2n, 'pick', 1);
// @ts-expect-error mixed signature retains string input
chooseWideInt(true, 1n, 2n, 1n, 1);
// @ts-expect-error mixed signature retains double input
chooseWideInt(true, 1n, 2n, 'pick', 1n);
// @ts-expect-error nullable bigint int is not number
nullableWideInt(1);
// @ts-expect-error nullable default int is not bigint
nullableInt(1n);
// @ts-expect-error nullable BigInt is not number
nullableBigInt(1);
// @ts-expect-error nullable does not mean optional
nullableBool();
// @ts-expect-error nullable does not mean optional
nullableString();
// @ts-expect-error nullable does not mean optional
nullableDouble();
// @ts-expect-error nullable does not mean optional
nullableInt();
// @ts-expect-error nullable does not mean optional
nullableBigInt();
// @ts-expect-error nullable does not mean optional
nullableWideInt();
// @ts-expect-error undefined is not null
nullableBool(undefined);
// @ts-expect-error undefined is not null
nullableString(undefined);
// @ts-expect-error undefined is not null
nullableDouble(undefined);
// @ts-expect-error undefined is not null
nullableInt(undefined);
// @ts-expect-error undefined is not null
nullableBigInt(undefined);
// @ts-expect-error undefined is not null
nullableWideInt(undefined);
// @ts-expect-error nullable result must be narrowed
const nonnullBool: boolean = optionalBoolean;
// @ts-expect-error nullable result must be narrowed
const nonnullString: string = optionalString;
// @ts-expect-error nullable result must be narrowed
const nonnullDouble: number = optionalDouble;
// @ts-expect-error nullable result must be narrowed
const nonnullInt: number = optionalInt;
// @ts-expect-error nullable result must be narrowed
const nonnullBigInt: bigint = optionalBigInt;
// @ts-expect-error nullable result must be narrowed
const nonnullWideInt: bigint = optionalWideInt;
