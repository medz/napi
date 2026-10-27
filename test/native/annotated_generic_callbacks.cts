import addon = require('./addon');

const results: Record<string, boolean> = addon.exercise(value => value);
const lists: boolean[] = addon.explicitLists(values => values);
const id = addon.identity();
const integer: number = id<number>(7);
const text: string = id<string>('hello');
const nullable: number | null = id<number | null>(null);
const object = { value: 7 };
const same: typeof object = id(object);
const origin: unknown = addon.origin(object, value => value);
const borrowedOrigin: unknown = addon.borrowedOrigin(object, value => value);
const asyncNative: Promise<boolean> = addon.asyncNative(async ({ value }) => value);
const asyncOrigin: Promise<unknown> = addon.asyncOrigin(object, async ({ value }) => value);
const independent: boolean = addon.independent((first, second) => first, value => Object(value));
const shadow: number = addon.shadow(7, value => value);
const nested: number = addon.nested(callback => callback);
const numeric: boolean[] = addon.numeric(value => value);
const bounded: number = addon.numericIdentity()<number>(1.5);
const nonNull: typeof object = addon.nonNullIdentity()(object);
const forward: number = new addon.Forward<number>(1.5).value;
const borrowed: boolean[] = addon.borrowed(value => value);
const optional: number[] = addon.optionalCalls((value, options = undefined) => options?.fallback ?? value);
const fallback: number = addon.fallbackIdentity()<number>(1, { fallback: 9 });
const counter = new addon.Counter(9);
const roundtrip: boolean = addon.counterRoundtrip(counter, value => value);
const captured: boolean = addon.capture(value => value);
const asynchronous: Promise<number> = addon.readCaptured(value => value);

// @ts-expect-error A generic callback must work for all its declared type arguments.
addon.exercise((value: number) => value);
// @ts-expect-error A generic callback preserves the relation between input and result.
addon.exercise(() => 'wrong');
// @ts-expect-error Explicit generic type arguments constrain the supplied value.
id<string>(7);
// @ts-expect-error The explicit outer List protocol is an Array, not a scalar.
addon.explicitLists(value => value[0]);
// @ts-expect-error Numeric generic bounds exclude strings.
addon.numericIdentity()<string>('wrong');
// @ts-expect-error Non-null Object bounds reject null.
addon.nonNullIdentity()(null);
// @ts-expect-error The later numeric parameter still constrains the first.
new addon.Forward<string>('wrong');
// @ts-expect-error Exact optional properties exclude explicit undefined for number.
addon.fallbackIdentity()<number>(1, { fallback: undefined });
