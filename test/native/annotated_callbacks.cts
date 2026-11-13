import addon = require('./addon');

const twice = addon.multiply(2);
const zeroView = addon.zeroView();
const optionalView = addon.optionalView();
const zeroValue: number = zeroView();
const defaultOptional: number = optionalView();
const explicitOptional: number = optionalView(2);
const applied: number = addon.apply(3, value => value + 1);
const doubleValue: number = addon.applyDouble(1.5, () => 2);
const same: (value: number) => number = addon.echoCallback(twice);
const nullable: ((value: number) => number) | null = addon.nullableCallback(null);
const omitted: ((value: number) => number) | null = addon.nullableCallback();
addon.saveCallback(twice);
const saved: ((value: number) => number) | null = addon.savedCallback();
addon.clearCallback();
addon.notify('notice', value => value.length);
const ignored: void = addon.numberRecorder()(4);
const text: string = addon.applyText('中文', value => value);
const integer: bigint = addon.bigintEcho()(1n << 100n);
addon.applyBigInt(1n, value => value);
addon.withDefault(3);
const positional = addon.positionalCallback();
const positionalValue: number = positional(1, 2, null);
positional(1);
addon.invokePositional((...args) => args.length);
addon.invokePositional(value => value);
addon.invokePositional((value, step = 1) => value + step);
addon.invokePositional(positional);
const named = addon.namedCallback();
const namedValue: string = named(1, { note: null });
named(1);
addon.invokeNamed((...args) => String(args.length));
addon.invokeNamed(value => String(value));
addon.invokeNamed((value, options = {}) => String(value + (options.step ?? 0)));
addon.invokeNamed(named);
const required: number = addon.requiredNamedCallback()({ value: 3 });
addon.invokeRequiredNamed(options => options.value);
const calculator = new addon.Calculator(3);
calculator.operation = twice;
const calculated: number = calculator.apply(4, twice);
const callbacks: ((value: number) => number)[] = addon.echoCallbacks([twice]);
const mapped: Record<string, (value: number) => number> = addon.callbackMap({ twice });
const box = new addon.Box(7);
const selected: addon.Box | null = addon.boxSelector(box)(true);
const nested: Record<string, addon.Box | null>[] = addon.nestedBoxes(box)();
addon.scheduleCallback(3, twice);
const delayed: number | null = addon.delayedResult();

// @ts-expect-error Callback results preserve their declared type.
addon.apply(1, value => String(value));
// @ts-expect-error Dart may omit the second argument.
addon.invokePositional((value: number, step: number) => value + step);
// @ts-expect-error Optional arguments still retain their value types.
addon.invokePositional((value: number, step?: string) => value);
// @ts-expect-error Dart may omit the options object.
addon.invokeNamed((value: number, options: { step?: number }) => String(value));
// @ts-expect-error A zero-argument view does not expose its implementation's optional parameter.
zeroView(2);
// @ts-expect-error An optional argument may be omitted but is not undefined.
optionalView(undefined);
// @ts-expect-error A callback is required, not an arbitrary object.
addon.apply(1, {});
// @ts-expect-error Nullable callbacks do not accept undefined.
addon.nullableCallback(undefined);
// @ts-expect-error Omission of a default does not accept explicit undefined.
addon.withDefault(1, undefined);
// @ts-expect-error Returned functions validate required arguments.
twice();
// @ts-expect-error Returned functions do not coerce strings.
twice('1');
// @ts-expect-error Function defaults distinguish omitted and undefined.
positional(1, undefined);
// @ts-expect-error Nullable function defaults still exclude undefined.
positional(1, 2, undefined);
// @ts-expect-error Optional options are omitted rather than undefined.
named(1, undefined);
// @ts-expect-error exactOptionalPropertyTypes applies to function options.
named(1, { note: undefined });
// @ts-expect-error Required named arguments need their options object.
addon.requiredNamedCallback()();
// @ts-expect-error The value field is required.
addon.requiredNamedCallback()({});
// @ts-expect-error Class function fields preserve callback results.
calculator.operation = value => String(value);
// @ts-expect-error BigInt callback types do not accept Number.
addon.bigintEcho()(1);
