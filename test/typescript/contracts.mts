import { add, echoInt, echoDouble, negate, echoString, accept, unsafeOutput, fail, api, $echo } from '@napi/foundation-fixture';
const collision: number = api($echo(3));
void collision;
const sum: number = add(1, 2);
const integer: number = echoInt(1);
const real: number = echoDouble(1.5);
const flag: boolean = negate(false);
const label: string = echoString('text');
const nothing: void = accept('text');
const checked: number = unsafeOutput();
const failure: string = fail('state');
void [sum, integer, real, flag, label, nothing, checked, failure];
// @ts-expect-error String is not a number.
add('1', 2);
// @ts-expect-error Required argument is missing.
add(1);
// @ts-expect-error Boolean is not a number.
echoDouble(true);
// @ts-expect-error Number is not a boolean.
negate(1);
// @ts-expect-error Nullable strings are outside the foundation slice.
echoString(null);
// @ts-expect-error No optional parameters.
accept();
// @ts-expect-error Integer result is not a string.
const wrong: string = echoInt(1);
// @ts-expect-error BigInt is not the safe-number integer representation.
echoInt(1n);
