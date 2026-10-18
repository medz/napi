import * as api from '@napi/void-fixture';
import * as direct from '@napi/void-fixture/BACKEND';
import * as external from '@napi/void-external';
const empty: void = api.empty();
const required: void = api.requiredValue(1);
const optional: void = api.optionalValue();
const positionalDefault: void = api.optionalValue(undefined);
const named: void = api.namedValue({value: 1, label: '雪'});
api.numbers([1, 2]);
api.namedValue(); api.namedValue(undefined); api.namedValue({value: undefined});
api.requiredNamed({value: null}); api.requiredNamed({value: 2});
const subpath: void = direct.requiredValue(1);
const selected: void = external.optionalValue();
// @ts-expect-error Required arguments remain required.
api.requiredValue();
// @ts-expect-error Void calls do not produce numbers.
const result: number = api.requiredValue(1);
// @ts-expect-error A synchronous void call is not a Promise.
const pending: Promise<void> = api.empty();
// @ts-expect-error Optional nonnullable parameters reject null.
api.optionalValue(null);
// @ts-expect-error Required named parameters remain required.
api.requiredNamed({});
// @ts-expect-error Required nullable parameters reject undefined.
api.requiredNamed({value: undefined});
// @ts-expect-error Unknown named parameters are not accepted.
api.namedValue({extra: 1});
void [empty, required, optional, positionalDefault, named, subpath, selected];
