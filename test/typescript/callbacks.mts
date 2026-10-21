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

type CallbackPayload = {raw: boolean} | undefined;
const containersInput = {
  values: new Map([['one', [{value: 1}, null]]]),
  payloads: {one: {raw: true}, absent: undefined, nil: null},
  references: [box, null], resource: null,
};
const containers: {
  values: Map<string, Array<api.CallbackValue | null>>;
  payloads: Record<string, CallbackPayload | null>;
  references: Array<api.CallbackBox | null>; resource: api.CallbackResource | null;
} = api.callContainers<CallbackPayload>(value => ({...value, values: new Map([['two', [{value: 2}]]])}), containersInput);
const asyncContainers: Promise<typeof containers> = api.callAsyncContainers<CallbackPayload>(async value => value, containersInput);
const keyMap: Map<api.CallbackValue, number> = api.callKeyMap(() => new Map([[{value: 1}, 2]]));
const normalized: api.CallbackNormalized = api.callNormalized(value => ({source: String(value.value)}), '1');
const selected: api.CallbackSelectedValue = api.selectValue({source: 1});
const selectedExternal: externalHandles.CallbackSelectedValue = externalHandles.selectValue({source: 1, offset: 2});
const selectedDirect: api.CallbackSelectedValue = direct.selectValue({source: 1});
// @ts-expect-error Explicit constructor input uses source, not the unnamed fallback's value.
api.selectValue({value: 1});
// @ts-expect-error Explicit constructor parameters retain their declared types.
api.selectValue({source: '1'});
const projection: number = api.callProjection(value => value.value);
const emptyProjection: number = api.readProjectionCallback(() => [null]);
const callbackReference: api.CallbackBox | null = api.callReference(value => value, box);
api.callReference(() => null, null);
const callbackResource: number = api.callNewResource(value => value, 1);
const asyncCallbackResource: Promise<number> = api.callAsyncNewResource(async value => value, 1);
const startedResource: void = api.startResourceCallback(async value => {void value;}, 1);
const rawPayload: CallbackPayload = api.callPayload<CallbackPayload>(value => value, undefined);
const asyncRawPayload: Promise<CallbackPayload> = api.callAsyncPayload<CallbackPayload>(async value => value, undefined);
api.callPayload<() => number>(value => value, () => 1);
const payloadBox = new api.CallbackPayloadBox<CallbackPayload>();
const rememberedPayload: CallbackPayload = payloadBox.remember(value => value, {raw: true});
const savedPayload: CallbackPayload = payloadBox.saved();
const invokedPayload: CallbackPayload = payloadBox.invoke(undefined);
payloadBox.clear();
api.rejectCallbackPayload<CallbackPayload>(() => ({$1: undefined, $2: {value: 1}}));
const externalPayload: CallbackPayload = externalHandles.callPayload<CallbackPayload>(value => value, undefined);
const externalNormalized: externalHandles.CallbackNormalized = externalHandles.callNormalized(value => ({source: String(value.value)}), '1');
// @ts-expect-error Value callback results use constructor input properties.
api.callNormalized(value => value, '1');
// @ts-expect-error Value fields retain strict Dart constructor types.
api.callContainers<CallbackPayload>(value => ({...value, values: new Map([['bad', [{value: 'bad'}]]])}), containersInput);
// @ts-expect-error Dictionary payloads retain the enclosing opaque parameter.
api.callContainers<CallbackPayload>(value => ({...value, payloads: {one: 1}}), containersInput);
// @ts-expect-error Selected reference results cannot be plain lookalikes.
api.callReference(() => ({value: 1}), null);
// @ts-expect-error Different selected classes retain distinct reference brands.
api.callReference(() => resource, box);
// @ts-expect-error Resource callback results remain the declared resource class.
api.callNewResource(() => box, 1);
// @ts-expect-error Callback resource Futures require an outer Promise.
api.callAsyncNewResource(value => value, 1);
// @ts-expect-error Opaque callback result Futures still require a Promise.
api.callAsyncPayload<CallbackPayload>(value => value, undefined);
// @ts-expect-error A required opaque value that admits undefined is still required.
api.callPayload<CallbackPayload>(value => value);
void [containers, asyncContainers, keyMap, normalized, selected, selectedExternal, selectedDirect, projection, emptyProjection,
  callbackReference, callbackResource, asyncCallbackResource, startedResource, rawPayload,
  asyncRawPayload, rememberedPayload, savedPayload, invokedPayload, externalPayload, externalNormalized];

const optionalPositionals: number[] = api.callOptionalPositionals((value = 7) => value);
const nullablePositionals: Array<number | null> = api.callNullablePositionals((value = 7) => value);
type OptionalPayload = {fallback: boolean} | undefined;
const defaultPayload: OptionalPayload = {fallback: true};
const opaquePositionals: Array<OptionalPayload | null> = api.callOpaquePositionals<OptionalPayload>(
  (value = defaultPayload) => value, undefined);
const optionalNames: number[] = api.callOptionalNames(options =>
  (options?.callback ?? 0) + (options?.operation ?? 0) + (options?.arguments ?? 0) +
  (options?.value ?? 0) + (options?.env ?? 0) + (options?.adapter ?? 0) + (options?.state ?? 0));
const namedPair = (options?: {a?: number; b?: number}): number => (options?.a ?? 0) + (options?.b ?? 0);
const namesAB: number[] = api.callNamesAB(namedPair);
const namesBA: number[] = api.callNamesBA(namedPair);
externalHandles.callNamesBA(namedPair); direct.callNamesAB(namedPair);
const mixedNames: number[] = api.callMixedNames((value, options) =>
  value + options.operation + options.constructor + (options.callback ?? 0));
const requiredNames: number = api.callRequiredNames(options => options.constructor);
const optionalModels: number[] = api.callOptionalModels(options =>
  (options?.resource?.id ?? 0) + (options?.value?.step ?? 0), 907);
const asyncOptionalPositionals: Promise<number[]> = api.callAsyncOptionalPositionals(async (value = 7) => value);
const asyncOptionalNames: Promise<Array<OptionalPayload | null>> = api.callAsyncOptionalNames<OptionalPayload>(
  async ({value = defaultPayload} = {}) => value, undefined);
const optionalDirect: number[] = direct.callOptionalPositionals((value = 7) => value);
const optionalExternal: number = externalHandles.callRequiredNames(options => options.constructor);
const policy = () => 0;
const parameterPolicies: boolean = api.callbackParameterPolicies(policy, policy, policy, policy, policy);
// @ts-expect-error An omitted argument does not make a non-null result optional.
api.callOptionalPositionals(value => value);
// @ts-expect-error Optional scalar arguments retain their declared type.
api.callOptionalPositionals((value?: string) => value?.length ?? 7);
// @ts-expect-error Required named parameters retain their scalar types.
api.callRequiredNames((options: {constructor: string}) => options.constructor.length);
// @ts-expect-error Synchronous callback results do not accept Promises.
api.callOptionalPositionals(async (value = 7) => value);
// @ts-expect-error Future callbacks still require a Promise.
api.callAsyncOptionalPositionals((value = 7) => value);
// @ts-expect-error Nullable scalar results exclude undefined.
api.callNullablePositionals(() => undefined);
// @ts-expect-error Opaque Future results still require an outer Promise.
api.callAsyncOptionalNames<OptionalPayload>(() => defaultPayload, undefined);
void [optionalPositionals, nullablePositionals, opaquePositionals, optionalNames, namesAB, namesBA, mixedNames,
  requiredNames, optionalModels, asyncOptionalPositionals, asyncOptionalNames,
  optionalDirect, optionalExternal, parameterPolicies];

const adder: (value: number) => number = api.makeAdder(2);
const sum: number = adder(3);
const optionalAdder: (value?: number) => number = api.makeOptionalAdder(2);
optionalAdder(); optionalAdder(undefined);
const namedAdder: (options: {constructor: number; value?: number; nullable?: number | null}) => number =
  api.makeNamedAdder(2);
namedAdder({constructor: 1}); namedAdder({constructor: 1, nullable: null});
const nullableAdder: ((value: number) => number) | null = api.nullableAdder(false);
const futureAdder: Promise<(value: number) => number> = api.futureAdder(2);
const asyncAdder: (value: number) => Promise<number> = api.makeAsyncAdder(2);
const streamAdder: (value: number) => AsyncIterableIterator<number, undefined, undefined> = api.makeStreamAdder(2);
for await (const value of streamAdder(3)) {
  const item: number = value; void item;
}
const functionContainers: {
  $1: Array<((value: number) => number) | null>;
  map: Map<string, (value: number) => number>;
  dictionary: Record<string, (value: number) => number>;
} = api.functionContainers(2);
const consumedFunctions: number = api.useFunctionContainers(functionContainers);
const transformed: (value: number) => number = api.transformFunction(value => number => value(number) * 2, 2);
const echoed: (value: number) => number = api.echoFunction(adder);
const functionValue: api.CallbackFunctionValue = api.echoFunctionValue({callback: adder});
const functionFieldResult: number = functionValue.callback(3);
const storedCallback: ((value: number) => number) | null = box.storedCallback;
box.callback = functionValue.callback;
const externalFunctionValue: externalHandles.CallbackFunctionValue = externalHandles.echoFunctionValue({callback: adder});
const composer: (callback: (value: number) => number) => (value: number) => number = api.composeFunction(2);
const normalizedFunction: (value: {source: string}) => api.CallbackNormalized = api.normalizedFunction();
const normalizedOutput: api.CallbackNormalized = normalizedFunction({source: '12'});
const echoedNormalized: (value: {source: string}) => api.CallbackNormalized =
  api.echoNormalizedFunction(value => ({source: String(value.value)}));
const positionalDefaults: (first?: number, second?: number) => number = api.positionalDefaults();
positionalDefaults(); positionalDefaults(2); positionalDefaults(2, undefined);
const canonical: boolean = api.isCanonicalFunction(api.requiredFunction());
api.optionalFunction()();
const capturedPayload: () => CallbackPayload = api.capturePayload<CallbackPayload>(undefined);
const capturedFunction: () => (value: number) => number = api.capturePayload(adder);
const rejectedFunction: {$1: () => CallbackPayload; $2: number} = api.rejectFunctionResult<CallbackPayload>(undefined);
const resourceFunction: (value: api.CallbackResource) => api.CallbackResource = api.resourceFunction();
const asyncResourceFunction: (value: api.CallbackResource) => Promise<api.CallbackResource> = api.asyncResourceFunction();
const resourceStreamFunction: (value: api.CallbackResource) => AsyncIterableIterator<api.CallbackResource, undefined, undefined> =
  api.resourceStreamFunction();
api.startFunctionOnlyCallback(resource, async callback => {void callback;});
const externalStream: AsyncIterableIterator<number, undefined, undefined> = externalHandles.makeStreamAdder(2)(3);
const directStream: AsyncIterableIterator<number, undefined, undefined> = direct.makeStreamAdder(2)(3);
const externalAdder: (value: number) => number = externalHandles.makeAdder(2);
const directAdder: (value: number) => number = direct.makeAdder(2);
// @ts-expect-error Returned functions preserve required positional parameters.
adder();
// @ts-expect-error Returned function inputs retain their strict scalar type.
adder('3');
// @ts-expect-error A nullable returned function must be checked before invocation.
nullableAdder(3);
// @ts-expect-error Named function parameters require the trailing options object.
api.makeNamedAdder(2)();
// @ts-expect-error The required named constructor property stays required.
api.makeNamedAdder(2)({value: 3});
// @ts-expect-error Optional non-null parameters exclude null.
optionalAdder(null);
// @ts-expect-error Returned functions are callable, not constructors.
new adder(3);
// @ts-expect-error A higher-order callback must return a function.
api.transformFunction(() => 3, 2);
// @ts-expect-error A function-valued field retains its declared result type.
api.echoFunctionValue({callback: () => 'bad'});
// @ts-expect-error Function-valued fields preserve their required input type.
functionValue.callback('3');
// @ts-expect-error Function-valued getters retain their callable signature.
box.storedCallback?.('3');
// @ts-expect-error Function container leaves retain their callable result type.
api.useFunctionContainers({$1: [() => 'bad'], map: functionContainers.map, dictionary: functionContainers.dictionary});
// @ts-expect-error A value function accepts constructor input properties, not getter outputs.
api.normalizedFunction()({value: 12});
// @ts-expect-error Input callbacks consume getter outputs and return constructor input properties.
api.echoNormalizedFunction(value => value);
// @ts-expect-error A resource function preserves the selected resource brand.
resourceFunction(box);
// @ts-expect-error Stream function inputs retain their declared scalar type.
streamAdder('3');
// @ts-expect-error Stream functions return an iterator, not a Promise.
const promisedStream: Promise<number> = streamAdder(3);
// @ts-expect-error Resource stream functions preserve the selected resource brand.
resourceStreamFunction(box);
void [sum, namedAdder, futureAdder, asyncAdder, consumedFunctions, transformed, echoed,
  functionFieldResult, storedCallback, externalFunctionValue,
  canonical, composer, normalizedOutput, echoedNormalized, positionalDefaults, capturedPayload,
  capturedFunction, rejectedFunction, resourceFunction, asyncResourceFunction, resourceStreamFunction,
  externalAdder, directAdder, externalStream, directStream, promisedStream];

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
