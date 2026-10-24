import {Counter, singleton, add} from '@napi/fallback-fixture';
import {Counter as NativeCounter} from '@napi/fallback-fixture/native';
const counter: Counter = singleton();
const native: NativeCounter = counter;
const value: number = add(new Counter(2).increment());
// @ts-expect-error Dart integer inputs do not accept strings.
new Counter('2');
// @ts-expect-error Dart integer inputs do not accept strings.
add('3');
