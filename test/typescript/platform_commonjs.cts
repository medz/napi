import napi = require('@napi/platform-fixture');
import native = require('@napi/platform-fixture/native');
import type {Counter as EsmCounter} from '@napi/platform-fixture' with {'resolution-mode': 'import'};

const esmCounter: EsmCounter = new napi.Counter(3);
const cjsCounter: napi.Counter = esmCounter;
const nativeCounter: native.Counter = cjsCounter;
const singleton: napi.Counter = native.singleton();
const value: number = nativeCounter.increment(napi.add(2));
void [singleton, value];
// @ts-expect-error The synchronous selector preserves constructor argument types.
new napi.Counter('3');
// @ts-expect-error The native subpath retains function parameter types.
native.add('2');
