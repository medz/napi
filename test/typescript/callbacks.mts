import * as api from '@napi/callback-fixture';
import * as direct from '@napi/callback-fixture/BACKEND';
import {plainCallback} from '@napi/callback-external';

const twice: number = api.callTwice(n => n + 1, 3);
const string: string = api.callString(s => s + '!', 'hello');
const bigint: bigint = api.callBigInt(n => n + 1n, 1n);
const wide: bigint = api.callWide(n => n + 1n, 1n);
const bool: boolean = api.callBool(b => !b, true);
const number: number = api.callDouble(n => n / 2, 1);
const list: number[] = api.callList(value => [...value, 3]);
const record: {$1: number[]; label: string} = api.callRecord(
  row => ({$1: [...row.$1, 3], label: row.label}), {$1: [1], label: 'row'});
const nested: Array<Array<number | null>> | null = api.callNested(value => value, [[1, null]]);
const ordered: number = api.callbackArgumentOrder((value, list) => value + list.length);
api.callNested(() => null, null);
api.callVoid(n => { void n; });
// A void callback discards its result; it never observes or awaits a Promise.
api.callVoid(async n => n);
api.optionalCallback();
api.optionalCallback(undefined);
api.optionalCallback(null);
api.optionalCallback(n => n);
api.namedCallback({callback: n => n});
api.namedCallback({callback: n => n, value: undefined});
const box = new api.CallbackBox(() => 7);
const applied: number = box.apply(n => n + 1);
const named: api.CallbackBox = api.CallbackBox.named(n => n + 1, 2);
named.callback = n => n + 3;
const setterValue: number = named.value;
const storedInvocation: number = named.invokeStored();
const resource = new api.CallbackResource(1);
resource.apply(n => n);
const closing: Promise<void> = resource.close();
const directResult: number = direct.callTwice(n => n, 1);
const external: number = plainCallback(n => n, 1);
const saved: Promise<number> = api.rethrowSavedFuture();

// @ts-expect-error A callback and scalar argument are both required.
api.callTwice();
// @ts-expect-error Non-null callback cannot be null.
api.callTwice(null, 1);
// @ts-expect-error Callback argument scalar types are exact even without strictFunctionTypes.
api.callTwice((n: string) => n.length, 1);
// @ts-expect-error Callback results retain their Dart type.
api.callTwice(() => 'bad', 1);
// @ts-expect-error A synchronous numeric callback cannot return a Promise.
api.callTwice(async n => n, 1);
// @ts-expect-error Non-null return is separate from nullable callback.
api.optionalCallback(() => null);
// @ts-expect-error Named options require a callback.
api.namedCallback({value: 3});
// @ts-expect-error A required named callback does not accept undefined.
api.namedCallback({callback: undefined});
// @ts-expect-error The bigint annotation applies inside callback signatures.
api.callWide((n: number) => n, 1n);
// @ts-expect-error Lists contain the declared scalar type.
api.callList(() => ['bad']);
// @ts-expect-error Named record fields preserve types.
api.callRecord(row => ({$1: row.$1, label: 1}), {$1: [], label: ''});
// @ts-expect-error Nested nullable containers do not accept strings.
api.callNested(() => [['bad']], null);
// @ts-expect-error Constructor callback result is checked.
new api.CallbackBox(() => 'bad');
// @ts-expect-error Named constructors require the callback and initial value.
api.CallbackBox.named(() => 1);
// @ts-expect-error Named constructor callback result is checked.
api.CallbackBox.named(() => 'bad', 1);
// @ts-expect-error Setter callback result must match the declared int result.
named.callback = () => 'bad';
// @ts-expect-error A non-null setter callback is required.
named.callback = undefined;
// @ts-expect-error The getter remains a scalar, not a callback value.
const notCallback: (value: number) => number = named.value;
// @ts-expect-error Member callback result is checked.
box.apply(() => undefined);
// @ts-expect-error External selection preserves the same callback signature.
plainCallback(() => 'bad', 1);
void [twice, string, bigint, wide, bool, number, list, record, nested, ordered, applied,
  closing, directResult, external, saved, named, setterValue, storedInvocation, notCallback];
