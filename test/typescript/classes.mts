import {Counter, Other, Scalars, Options, liveCounters} from '@napi/class-fixture';
import {Counter as Alias} from '@napi/class-fixture/module.wasm';
const counter: Counter = new Alias();
counter.value = counter.increment(undefined);
counter.named({amount: undefined});
counter.requiredNamed({amount: null});
const label: string = Counter.label();
const value: number = new Other().value;
const reset: void = counter.reset();
const count: number = liveCounters();
Counter.count = count;
const scalars = new Scalars();
scalars.integer = 1n;
scalars.nullable = null;
const empty: void = scalars.empty;
const tag: number = Scalars.constructor();
const option: string = new Options({amount: null}).label;
void [label, value, reset, option, empty, tag];
// @ts-expect-error scalar values are strict
counter.value = 'bad';
// @ts-expect-error readonly Dart field
new Other().value = 3;
// @ts-expect-error selected name replaces original name
counter.twice();
// @ts-expect-error ignored member is not exported
counter.hidden();
// @ts-expect-error required nullable remains required
counter.requiredNamed({amount: undefined});
// @ts-expect-error named constructor parameter is required
new Options();
// @ts-expect-error nullable field does not accept undefined
scalars.nullable = undefined;
// @ts-expect-error ordinary methods are not constructors
new counter.increment();
