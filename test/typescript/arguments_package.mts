import {optionalNumber, namedValues, requiredNamed} from '@napi/foundation-fixture';
import {optionalNumber as subpath} from '@napi/foundation-fixture/module.wasm';

const result: number = optionalNumber() + subpath(undefined);
const text: string = namedValues(result, {count: undefined});
const nullable: number | null = requiredNamed(result, {value: null});
// @ts-expect-error required named property is required
requiredNamed(result, {});
// @ts-expect-error required named property rejects undefined
requiredNamed(result, {value: undefined});
// @ts-expect-error nonnullable optional scalar rejects null
optionalNumber(null);
void [text, nullable];
