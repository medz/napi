import addon = require('./addon');

const booleanValue: boolean = addon.echoBool(true);
const integerValue: number = addon.echoInt(42);
const doubleValue: number = addon.echoDouble(1.5);
const numValue: number = addon.echoNum(1.5);
const stringValue: string = addon.echoString('中文');
const bigintValue: bigint = addon.echoBigInt(1n << 100n);
const nullValue: null = addon.echoNull(null);
const nullableBool: boolean | null = addon.echoNullableBool(null);
const nullableInt: number | null = addon.echoNullableInt(null);
const nullableDouble: number | null = addon.echoNullableDouble(null);
const nullableNum: number | null = addon.echoNullableNum(null);
const nullableString: string | null = addon.echoNullableString(null);
const nullableBigInt: bigint | null = addon.echoNullableBigInt(null);
const sum: number = addon.renamedAdd(20, 22);
const privateValue: number = addon.privateValue(17);
const ignored: void = addon.remember(42);
const remembered: number = addon.readRemembered();
const fail: () => never = addon.fail;

addon.positionalDefaults(3);
addon.positionalDefaults(3, 2);
addon.positionalDefaults(3, 2, 'label');
addon.positionalDefaults(3, 2, 'label', null);
addon.namedDefaults(3, { count: 2 });
addon.namedDefaults(3, { count: 2, label: 'label', maybe: null });
addon.optionalNamed();
addon.optionalNamed({});
addon.optionalNamed({ count: 2, maybe: null });

// @ts-expect-error Required arguments cannot be omitted.
addon.renamedAdd(1);
// @ts-expect-error Numbers are not coerced from strings.
addon.echoInt('1');
// @ts-expect-error BigInt stays distinct from Number.
addon.echoBigInt(1);
// @ts-expect-error Nullable arguments still reject undefined.
addon.echoNullableInt(undefined);
// @ts-expect-error Nullable results require a null check.
const nonNullable: number = addon.echoNullableInt(1);
// @ts-expect-error A required Null parameter still needs an argument.
addon.echoNull();
// @ts-expect-error An omitted Dart default does not accept explicit undefined.
addon.positionalDefaults(3, undefined);
// @ts-expect-error Later optional positions also reject explicit undefined.
addon.positionalDefaults(3, 2, 'label', undefined);
// @ts-expect-error Required named parameters need an options object.
addon.namedDefaults(3);
// @ts-expect-error The required named count cannot be omitted.
addon.namedDefaults(3, {});
// @ts-expect-error exactOptionalPropertyTypes rejects explicit undefined.
addon.namedDefaults(3, { count: 2, label: undefined });
// @ts-expect-error Nullable and optional do not include undefined.
addon.optionalNamed({ maybe: undefined });
// @ts-expect-error Omitting an options object differs from passing undefined.
addon.optionalNamed(undefined);
// @ts-expect-error Only the renamed JavaScript export exists.
addon.addNumbers(1, 2);
// @ts-expect-error Unannotated declarations are not exported.
addon.unannotated();
