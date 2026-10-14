import { add } from '@napi/foundation-fixture';
import { echo } from '@napi/foundation-fixture/module.wasm';
const result: number = echo(add(1, 2));
// @ts-expect-error fixed number contract
add('1', result);
