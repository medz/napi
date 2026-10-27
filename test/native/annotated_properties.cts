import addon = require('./addon');

addon.count = 3;
addon.lazyMutable = 20;
addon.crossValue = 12;
const crossValue: number = addon.crossValue;
const count: number = addon.count;
const lazy: number = addon.lazyFinal;
const deferred: number = addon.deferredFinal;
addon.nullableCount = null;
const reads: number = addon.reads;
const missing: undefined = addon.writeOnly;
addon.writeOnly = 7;
addon.display = 7;
const display: string = addon.display;
addon.operation = value => value * 3;
const operation: (value: number) => number = addon.operation;
const point: addon.Point = addon.point;
addon.point = { value: '7' };
const token: addon.Token = addon.token;
addon.token = new addon.Token(5);
const echoed: addon.Token = addon.echoToken(token);
addon.saved = {};
const saved: object | null = addon.saved;
addon.rejected = Symbol();

// @ts-expect-error Final properties are readonly.
addon.lazyFinal = 7;
// @ts-expect-error Late final properties are also readonly.
addon.deferredFinal = 7;
// @ts-expect-error Unmarked setters are not exported.
addon.reads = 7;
// @ts-expect-error Setter-only properties retain their input type.
addon.writeOnly = '7';
// @ts-expect-error Mutable fields retain strict types.
addon.count = '7';
// @ts-expect-error Nullable fields exclude undefined.
addon.nullableCount = undefined;
// @ts-expect-error Structural setters use constructor input, not output shape.
addon.point = point;
// @ts-expect-error Nominal class properties reject structural copies.
addon.token = { value: 7 };
// @ts-expect-error Nullable references exclude undefined.
addon.saved = undefined;
// @ts-expect-error Unmarked declarations are absent.
addon.hidden;
