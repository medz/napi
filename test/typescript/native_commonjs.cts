import napi = require('@napi/path');
import native = require('@napi/path/native');
import type {Counter as EsmCounter, RefBox as EsmRefBox} from '@napi/path' with {'resolution-mode': 'import'};

const esmCounter: EsmCounter = new napi.Counter(3);
const cjsCounter: napi.Counter = esmCounter;
const nativeCounter: native.Counter = cjsCounter;
const esmReference: EsmRefBox = new native.RefBox(7);
const cjsReference: napi.RefBox = esmReference;
const same: native.RefBox = napi.identityReference(cjsReference);
const value: number = nativeCounter.increment(2);
const executable: string = napi.executable();
void [same, value, executable];
// @ts-expect-error CommonJS constructors retain their argument types.
new napi.Counter('3');
// @ts-expect-error The native subpath preserves method argument types.
nativeCounter.increment('2');
// @ts-expect-error CommonJS references retain their nominal brand.
napi.identityReference({value: 7});
