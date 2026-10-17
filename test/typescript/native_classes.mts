import {Counter, Other, executable} from '@napi/path';
import {Counter as Alias} from '@napi/path/native';
const counter: Counter = new Alias();
counter.value = counter.increment(undefined);
counter.named({amount: undefined});
const label: string = Counter.label();
const value: number = new Other().value;
const path: string = executable();
void [label, value, path];
// @ts-expect-error scalar values are strict
counter.value = 'bad';
// @ts-expect-error readonly Dart field
new Other().value = 3;
// @ts-expect-error selected name replaces original name
counter.twice();
// @ts-expect-error ignored member is not exported
counter.hidden();
