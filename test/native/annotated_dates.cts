import addon = require('./addon');

const date: globalThis.Date = addon.echoDate(new Date());
const utc: boolean = addon.dateIsUtc(date);
const microseconds: globalThis.Date = addon.fromMicroseconds(-1);
const nullable: globalThis.Date | null = addon.nullableDate(null);
const dates: (globalThis.Date | null)[] = addon.echoDates([date, null]);
const bounced: (value: globalThis.Date) => globalThis.Date = addon.bounceDate(value => value);
const returned: globalThis.Date = bounced(date);

// @ts-expect-error DateTime inputs require Date objects.
addon.echoDate(0);
// @ts-expect-error A getTime method alone does not describe a Date.
addon.echoDate({ getTime: () => 0 });
// @ts-expect-error Nullable DateTime values exclude undefined.
addon.nullableDate(undefined);
// @ts-expect-error DateTime callbacks return Date objects.
addon.bounceDate(() => 7);
