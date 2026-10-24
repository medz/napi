import native = require('@napi/dual-fixture/native');
import external = require('@napi/dual-external');
import selected = require('@napi/dual-external/native');
import type {Counter as NativeCounter} from '@napi/dual-fixture/native' with {'resolution-mode': 'import'};
import type {Counter as ExternalCounter} from '@napi/dual-external' with {'resolution-mode': 'import'};

const esmCounter: NativeCounter = new native.Counter(3);
const cjsCounter: native.Counter = esmCounter;
const externalCounter: ExternalCounter = new external.Counter(5);
const selectedCounter: selected.Counter = externalCounter;
const same: external.Counter = selected.identity(selectedCounter);
const value: number = native.identity(cjsCounter).increment(2);
const later: Promise<number> = external.later(value);
void [same, later];
// @ts-expect-error Native CommonJS functions retain strict scalar parameters.
native.add('3');
// @ts-expect-error A native-root package preserves constructor argument types.
new external.Counter('5');
// @ts-expect-error Separately built packages still own distinct reference brands.
native.identity(selectedCounter);
