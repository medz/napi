import addon = require('./addon');

const a: addon.Counter = new addon.Counter();
const b: addon.Counter = new addon.Counter(5);
const named: addon.Counter = addon.Counter.named({ value: 6, note: null });
const defaultNamed: addon.Counter = addon.Counter.named();
const zero: addon.Counter = addon.Counter.zero();
const same: addon.Counter = a.same();
const echoed: addon.Counter = addon.echoCounter(a);
const nullable: addon.Counter | null = addon.echoNullableCounter(null);
const omitted: addon.Counter | null = addon.echoNullableCounter();
const factory: addon.FactoryCounter = new addon.FactoryCounter();
const namedOnly: addon.NamedOnly = addon.NamedOnly.create();
const child: addon.Counter = addon.derived();
const shared: addon.Counter = addon.sharedCounter();
const kind: string = a.kind;
const note: string | null = a.note;
const increment: number = a.increment();
const namedStep: string = child.namedStep({ note: 'explicit' });
a.value = 3;
a.doubled = 42;
a.note = null;
a.peer = b;
const peer: addon.Counter | null = a.peer;
a.peer = null;
a.reset();
addon.Counter.created = 0;
addon.Counter.limit = 17;

// @ts-expect-error Final Dart fields are readonly.
a.kind = 'other';
// @ts-expect-error Classes without unnamed constructors expose only factories.
new addon.NamedOnly();
// @ts-expect-error Nullable Dart fields do not accept undefined.
a.note = undefined;
// @ts-expect-error Class nullability must be explicit.
addon.echoCounter(null);
// @ts-expect-error Nullable class inputs still reject undefined.
addon.echoNullableCounter(undefined);
// @ts-expect-error Distinct wrapped classes are incompatible.
addon.echoCounter(new addon.Other());
declare const structural: { [K in keyof addon.Counter]: addon.Counter[K] };
// @ts-expect-error A structural copy has no native class identity.
addon.echoCounter(structural);
// @ts-expect-error Class fields preserve nominal wrapped-class types.
a.peer = structural;
// @ts-expect-error Nullable class fields reject another wrapped class.
a.peer = new addon.Other();
// @ts-expect-error Nullable class fields do not accept undefined.
a.peer = undefined;
// @ts-expect-error Nullable class output requires a null check.
const notNullable: addon.Counter = addon.echoNullableCounter(a);
// @ts-expect-error Constructor defaults distinguish omitted and undefined.
new addon.Counter(undefined);
// @ts-expect-error Named constructor fields preserve exact optional types.
addon.Counter.named({ value: undefined });
// @ts-expect-error Renamed private members expose only their JS name.
a._reset();
