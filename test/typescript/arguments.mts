import {
  argumentCalls, requiredNullable, optionalNumber, optionalNullable,
  optionalNull, optionalValues, optionalText, optionalDouble, optionalNaN,
  optionalInfinity, optionalNegativeInfinity, optionalWide, optionalBigInt,
  namedValues, requiredNamed, namedWide, manyNamed, optionalFailure,
} from './module.wasm';

const calls: number = argumentCalls();
const nullable: number | null = requiredNullable(null);
const optional: number = optionalNumber();
optionalNumber(undefined);
optionalNumber(0);
optionalNullable();
optionalNullable(undefined);
optionalNullable(null);
optionalNull();
optionalNull(undefined);
optionalNull(null);
optionalValues();
optionalValues(undefined, 0, '');
optionalValues(false, undefined, '');
optionalText();
optionalText(undefined);
optionalDouble();
optionalNaN(undefined);
optionalInfinity();
optionalNegativeInfinity();
const wide: bigint = optionalWide();
optionalWide(undefined);
optionalWide(0n);
const big: bigint | null = optionalBigInt();
optionalBigInt(undefined);
optionalBigInt(1n << 300n);
namedValues(0);
namedValues(0, undefined);
namedValues(0, {});
namedValues(0, {count: undefined, flag: undefined, label: undefined, maybe: undefined});
namedValues(0, {count: 0, flag: false, label: '', maybe: null});
requiredNamed(0, {value: null});
requiredNamed(0, {value: 0, flag: undefined});
namedWide();
namedWide(undefined);
namedWide({value: undefined, flag: undefined});
namedWide({value: 0n});
manyNamed();
manyNamed({p00: 0, p31: 0, p32: undefined, p34: 0});
optionalFailure();

type Equal<A, B> = (<T>() => T extends A ? 1 : 2) extends (<T>() => T extends B ? 1 : 2) ? true : false;
type Assert<T extends true> = T;
type ArgumentSignatures = [
  Assert<Equal<typeof requiredNullable, (value: number | null) => number | null>>,
  Assert<Equal<typeof optionalNumber, (value?: number) => number>>,
  Assert<Equal<typeof optionalNullable, (value?: number | null) => number | null>>,
  Assert<Equal<typeof optionalNull, (value?: number | null) => number | null>>,
  Assert<Equal<typeof optionalValues, (flag?: boolean, count?: number, label?: string) => string>>,
  Assert<Equal<typeof optionalWide, (value?: bigint) => bigint>>,
  Assert<Equal<typeof optionalBigInt, (value?: bigint | null) => bigint | null>>,
  Assert<Equal<typeof namedValues, (prefix: number, options?: {
    count?: number | undefined;
    flag?: boolean | undefined;
    label?: string | undefined;
    maybe?: number | null | undefined;
  }) => string>>,
  Assert<Equal<typeof requiredNamed, (prefix: number, options: {
    value: number | null;
    flag?: boolean | undefined;
  }) => number | null>>,
  Assert<Equal<typeof namedWide, (options?: {
    value?: bigint | undefined;
    flag?: boolean | undefined;
  }) => bigint>>,
];

// @ts-expect-error nullable required positional does not allow omission
requiredNullable();
// @ts-expect-error nullable required positional does not allow undefined
requiredNullable(undefined);
// @ts-expect-error nonnullable optional values reject null
optionalNumber(null);
// @ts-expect-error optional scalar inputs never coerce
optionalNumber('7');
// @ts-expect-error position holes do not change the scalar representation
optionalValues(undefined, false);
// @ts-expect-error callable global exports have no constructor signature
new optionalNumber();
// @ts-expect-error optional wide int has one fixed bigint representation
optionalWide(0);
// @ts-expect-error nullable Dart BigInt does not accept number
optionalBigInt(0);
// @ts-expect-error required positional before options cannot be omitted
namedValues();
// @ts-expect-error the options object is not a list of positional arguments
namedValues(0, 1);
// @ts-expect-error null is not an options object
namedValues(0, null);
// @ts-expect-error optional nonnullable named fields reject null
namedValues(0, {count: null});
// @ts-expect-error unknown named keys are not declared
namedValues(0, {unknown: 1});
// @ts-expect-error a required named property makes the options object required
requiredNamed(0);
// @ts-expect-error the required options object cannot be undefined
requiredNamed(0, undefined);
// @ts-expect-error the required nullable property cannot be omitted
requiredNamed(0, {});
// @ts-expect-error required nullable means null, not undefined
requiredNamed(0, {value: undefined});
// @ts-expect-error scalar bigint representation remains fixed for named fields
namedWide({value: 0});
// @ts-expect-error nullable result must be narrowed
const nonnull: number = optionalNullable();
// @ts-expect-error runtime surplus arguments are not part of the declared API
optionalNumber(1, 2);
void [calls, nullable, optional, wide, big];
