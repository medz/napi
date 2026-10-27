import addon = require('./addon');

const values: Set<number> = addon.echoInts(new Set([3, 1, 2]));
const last: Set<number> = addon.lastInts();
const nested: (Set<number | null> | null)[] = addon.echoNested([new Set([1, null]), null]);
const dates: Set<globalThis.Date> = addon.echoDates(new Set([new Date()]));
const numbers: Set<number> = addon.specialNumbers();
const key = new addon.Key(7);
const keys: Set<addon.Key> = addon.echoKeys(new Set([key]));
const objects: Set<object> = addon.echoObjects(new Set([{}]));
const callback: (value: Set<number>) => Set<number> = addon.bounceSet(value => value);

// @ts-expect-error Set elements retain their declared type.
addon.echoInts(new Set(['3']));
// @ts-expect-error Nullable set elements exclude undefined.
addon.echoNested([new Set([undefined])]);
// @ts-expect-error DateTime set elements require Dates.
addon.echoDates(new Set([7]));
// @ts-expect-error Bound class set elements retain nominal identity.
addon.echoKeys(new Set([{ value: 7 }]));
// @ts-expect-error Reference set elements require JavaScript objects.
addon.echoObjects(new Set([7]));
// @ts-expect-error Typed set callbacks return matching element types.
addon.bounceSet(() => new Set(['3']));
