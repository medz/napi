import {Counter, add} from '@napi/platform-fixture';
import {Counter as NativeCounter, singleton} from '@napi/platform-fixture/native';
import {Counter as WasmCounter} from '@napi/platform-fixture/wasm';

const constructor: typeof Counter = NativeCounter;
const value: number = new constructor().increment(add(2));
const same: Counter = singleton();
const wasmValue: number = new WasmCounter(3).increment();
void [value, same, wasmValue];
// @ts-expect-error The assembled entry preserves constructor argument types.
new Counter('3');
// @ts-expect-error The explicit native entry has the same method argument types.
new NativeCounter().increment('1');
