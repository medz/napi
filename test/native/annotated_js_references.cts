import addon = require('./addon');

const object = { value: 7 };
const opaque: unknown = addon.echoValue(object);
const dynamic: any = addon.echoDynamic(object);
const nonNull: {} | undefined = addon.echoNonNull(undefined);
const objectReference: object = addon.echoObject(object);
const functionReference: globalThis.Function = addon.echoFunction((value: number) => value);
const symbolReference: symbol = addon.echoSymbol(Symbol());
const optionalObject: object | null = addon.optionalObject();
const undefinedValue: undefined = addon.echoUndefined(undefined);
const optionalUndefined: undefined | null = addon.optionalUndefined();
const values: unknown[] = addon.echoValues([object, undefined, null]);
const symbols: symbol[] = addon.echoSymbols([Symbol()]);
const applied: unknown = addon.applyValue(object, value => value);
const stream: AsyncIterableIterator<symbol> = addon.symbolStream(Symbol());
addon.saveValue(object);
const saved: unknown = addon.savedValue();
const later: Promise<unknown> = addon.savedLater();
addon.clearValue();
addon.echoNonNull(7);
addon.echoNonNull('text');
addon.echoNonNull(Symbol());
addon.presence();
addon.presence(undefined);
addon.presence(null);
dynamic.anything.deep;

// @ts-expect-error Object? results must be narrowed by callers.
opaque.value;
// @ts-expect-error Object excludes null.
addon.echoNonNull(null);
// @ts-expect-error Object references exclude scalar inputs.
addon.echoObject(7);
// @ts-expect-error Object references exclude symbols.
addon.echoObject(Symbol());
// @ts-expect-error Function references require a callable value.
addon.echoFunction({});
// @ts-expect-error Symbol references require a Symbol.
addon.echoSymbol('symbol');
// @ts-expect-error Optional nullable object references exclude undefined.
addon.optionalObject(undefined);
// @ts-expect-error JsUndefined excludes null.
addon.echoUndefined(null);
// @ts-expect-error Typed references remain strict inside lists.
addon.echoSymbols([Symbol(), object]);
