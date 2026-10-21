import * as api from '@napi/callback-fixture';
import * as direct from '@napi/callback-fixture/BACKEND';
import {plainCallback, plainAsyncCallback} from '@napi/callback-external';
import * as externalHandles from '@napi/callback-external';

const twice: number = api.callTwice(n => n + 1, 3);
const string: string = api.callString(s => s + '!', 'hello');
const bigint: bigint = api.callBigInt(n => n + 1n, 1n);
const wide: bigint = api.callWide(n => n + 1n, 1n);
const bool: boolean = api.callBool(b => !b, true);
const number: number = api.callDouble(n => n / 2, 1);
const list: number[] = api.callList(value => { value.push(3); return value; });
api.callList(() => [1, 2] as const);
const record: {$1: number[]; label: string} = api.callRecord(
  row => { row.$1.push(3); return {$1: row.$1, label: row.label} as const; },
  {$1: [1], label: 'row'} as const);
const nested: Array<Array<number | null>> | null = api.callNested(value => value, [[1, null]]);
const bytes = new Uint8Array([1, 2]);
const binary: Uint8Array<ArrayBuffer> = api.callBytes(value => value, bytes);
const buffer: ArrayBuffer = api.callBuffer(value => value, bytes.buffer);
const shared: Uint8Array<ArrayBuffer> | null = api.callShared(value => value, bytes);
api.callShared(() => null, null);
const binaryRow = {bytes: [bytes, null], buffer: bytes.buffer, shared: bytes};
const binaryRecord: {bytes: Array<Uint8Array<ArrayBuffer> | null>; buffer: ArrayBuffer | null; shared: Uint8Array<ArrayBuffer> | null} =
  api.callBinaryRecord(value => value, binaryRow);
const retainedBinary = api.invokeBinaryRecord({bytes: [null], buffer: null, shared: null});
api.clearBinaryCallback();
const binaryAsync: Promise<Uint8Array<ArrayBuffer> | null> = api.callAsyncBytes(async value => value, bytes);
const sharedAsync: Promise<Uint8Array<ArrayBuffer> | null> = api.callAsyncShared(async value => value, null);
const binaryAsyncRecord: Promise<typeof binaryRecord> = api.callAsyncBinaryRecord(async value => value, binaryRow);
const binaryDirect: Uint8Array<ArrayBuffer> = direct.callBytes(value => value, bytes);
const binaryExternal: Uint8Array<ArrayBuffer> = externalHandles.callBytes(value => value, bytes);
const sharedExternal: Promise<Uint8Array<ArrayBuffer> | null> = externalHandles.callAsyncShared(async value => value, bytes);
const binaryIdentity = <T,>(value: T): T => value;
api.binaryCallbackPolicies(binaryIdentity, binaryIdentity, binaryIdentity, binaryIdentity);
// @ts-expect-error Uint8List callback results use Uint8Array, not ArrayBuffer.
api.callBytes(value => value.buffer, bytes);
// @ts-expect-error ByteBuffer callback results use ArrayBuffer, not a typed array.
api.callBuffer(() => bytes, bytes.buffer);
// @ts-expect-error Shared-backed views cannot be callback snapshots.
api.callBytes(() => new Uint8Array(new SharedArrayBuffer(1)), bytes);
// @ts-expect-error SharedBytes retains its Uint8Array kind.
api.callShared(() => bytes.buffer, null);
// @ts-expect-error Nullable callback payloads still exclude undefined.
api.callShared(() => undefined, null);
// @ts-expect-error Future callbacks require a Promise around binary results.
api.callAsyncBytes(value => value, bytes);
// @ts-expect-error Promise fulfillment retains the binary storage policy.
api.callAsyncShared(async () => new Uint8Array(new SharedArrayBuffer(1)), null);
// @ts-expect-error Nested nullable binary leaves still exclude undefined.
api.callBinaryRecord(value => ({...value, buffer: undefined}), binaryRow);
void [binary, buffer, shared, binaryRecord, retainedBinary, binaryAsync, sharedAsync,
  binaryAsyncRecord, binaryDirect, binaryExternal, sharedExternal];
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
const after: Promise<number> = api.callAfter(n => n + 1, 3);
const asyncValue: Promise<number> = api.callAsync(async n => n + 1, 3);
const asyncVoid: Promise<void> = api.callAsyncVoid(async () => {});
const asyncWide: Promise<bigint> = api.callAsyncWide(async n => n + 1n, 1n);
const asyncRecord: Promise<{$1: Array<number | null>; label: string}> =
  api.callAsyncRecord(async row => {
    row.$1.push(null);
    return {$1: [...row.$1, null], label: row.label} as const;
  });
const asyncExternal: Promise<number> = plainAsyncCallback(async n => n + 1, 3);
const asyncResource: Promise<number> = resource.applyAsync(async n => n + 1);
const asyncCleanup: Promise<void> = new api.CallbackCleanup(2).close(async () => {});
const same: boolean = api.sameCallback(n => n, n => n);
api.optionalAsyncCallback(); api.optionalAsyncCallback(undefined); api.optionalAsyncCallback(null);
api.optionalAsyncCallback(async n => n + 1);
const registered: number = api.registerAsyncCallback(async n => n);
const removed: boolean = api.unregisterAsyncCallback(async n => n);

const handle: number[] = api.callHandle(value => value, [1]);
const handles: {arrays: Array<number[] | null>; map: Map<string, number | null>} =
  api.callHandles(value => value, {arrays: [[1], null], map: new Map([['key', null]])});
const nullableHandle: number[] | null = api.callNullableHandle(value => value, null);
const asyncHandle: Promise<number[]> = api.callAsyncHandle(async value => value, [1]);
const wideHandle: bigint[] = api.callWideHandle(value => value, [1n]);
type Payload = {id: number} | undefined;
const payloadInput = {arrays: [[undefined, {id: 1}]], map: new Map<Payload, Payload>()};
const payloadHandles: {arrays: Payload[][]; map: Map<Payload, Payload>} =
  api.callPayloadHandles<Payload>(value => value, payloadInput);
const externalHandle: number[] = externalHandles.callHandle(value => value, [1]);
const externalAsyncHandle: Promise<number[]> = externalHandles.callAsyncHandle(async value => value, [1]);
const orderedHandle: bigint = api.callbackHandleOrder(() => 1n, true, true);
// @ts-expect-error Callback handle results retain their element type.
api.callHandle(() => ['bad'], [1]);
// @ts-expect-error Callback argument policy applies to the raw array type.
api.callHandle((value: string[]) => value, [1]);
// @ts-expect-error Nullable handles still exclude undefined.
api.callNullableHandle(() => undefined, null);
// @ts-expect-error Future callbacks require an outer Promise.
api.callAsyncHandle(value => value, [1]);
// @ts-expect-error Async handle results retain their element type.
api.callAsyncHandle(async () => ['bad'], [1]);
// @ts-expect-error bigint policy also applies inside callbacks.
api.callWideHandle(() => [1], [1n]);
// @ts-expect-error Nested opaque handles use the enclosing generic parameter.
api.callPayloadHandles<Payload>(value => ({arrays: [[1]], map: value.map}), payloadInput);
// @ts-expect-error Nullable nested leaves exclude undefined.
api.callHandles(value => ({arrays: [undefined], map: value.map}), {arrays: [], map: new Map()});
void [handle, handles, nullableHandle, asyncHandle, wideHandle, payloadHandles,
  externalHandle, externalAsyncHandle, orderedHandle];

// @ts-expect-error Future callback results require a Promise, not a plain scalar.
api.callAsync(n => n + 1, 3);
// @ts-expect-error Promise payloads use the declared strict input type.
api.callAsync(async () => 'bad', 3);
// @ts-expect-error Future<void> still requires an outer Promise.
api.callAsyncVoid(() => {});
declare const like: PromiseLike<number>;
// @ts-expect-error A raw PromiseLike is not the declared genuine Promise.
api.callAsync(() => like, 3);
api.callAsync(() => Promise.resolve(like), 3);
// @ts-expect-error Integer policy applies inside Promise callback results.
api.callAsyncWide(async () => 1, 1n);
// @ts-expect-error Record element types remain strict after Promise fulfillment.
api.callAsyncRecord(async row => ({$1: ['bad'], label: row.label}));
// @ts-expect-error Future-returning exports may take a synchronous callback without changing its type.
api.callAfter(async n => n, 3);
// @ts-expect-error External async callbacks have the same Promise result contract.
plainAsyncCallback(n => n, 3);

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
  closing, directResult, external, saved, named, setterValue, storedInvocation, notCallback,
  after, asyncValue, asyncVoid, asyncWide, asyncRecord, asyncExternal, asyncResource, asyncCleanup, same,
  registered, removed];
