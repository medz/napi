import napi = require('@napi/fallback-fixture');
import native = require('@napi/fallback-fixture/native');
const counter: napi.Counter = new native.Counter(2);
const same: native.Counter = napi.singleton();
const value: number = napi.add(counter.increment());
// @ts-expect-error CommonJS preserves the same constructor input.
new napi.Counter('2');
// @ts-expect-error CommonJS preserves the same function input.
napi.add('3');
