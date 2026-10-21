import * as api from '@napi/js-collections-fixture';
import * as direct from '@napi/js-collections-fixture/BACKEND';
import * as external from '@napi/js-collections-external';
import * as nestedOnly from '@napi/js-collections-nested';
import * as copiedOnly from '@napi/js-collections-copied';
const array: number[] = api.remember([1]);
const same: number[] = direct.remember(external.remember(array));
const map: Map<string, number | null> = api.rememberMap(new Map([['a', 1], ['b', null]]));
const big: bigint[] = api.int64([1n]);
const wide: bigint[] = api.bigints([1n << 100n]);
const maybe: number[] | null = api.optional();
api.optional(undefined); api.optional(null); api.named(); api.named({value: array});
const nullable: (number | null)[] = api.nullable([null, 1]);
const holder = new api.Holder(array); holder.value = array;
const promise: Promise<number[]> = api.later(array);
const stream: AsyncIterableIterator<number[], undefined, undefined> = api.events(array);
const mapPromise: Promise<Map<string, number | null>> = api.laterMap(map);
const owner = new api.Owner(); const owned: Promise<number[]> = owner.retain(array);
// @ts-expect-error Required input cannot be omitted.
api.remember();
// @ts-expect-error Non-null input.
api.remember(null);
// @ts-expect-error Element type is strict.
api.remember(['x']);
// @ts-expect-error No implicit undefined element.
api.nullable([undefined]);
// @ts-expect-error bigint policy uses bigint.
api.int64([1]);
// @ts-expect-error Map keys are strings.
api.rememberMap(new Map([[1, 1]]));
// @ts-expect-error A collection handle is the original Array, not a facade.
array.get(0);
void [array, same, map, big, wide, maybe, nullable, holder, promise, stream, mapPromise, owned];

type Payload = {id: number} | undefined;
const payloads = new api.ArrayPayloads<Payload>([{id: 1}, undefined]);
const original: Array<Payload> = payloads.source();
payloads.put(0, undefined);
const saved: Payload | null = payloads.saved();
const nullablePayload: Array<Payload | null> = [null, undefined];
api.nullablePayload<Payload>(nullablePayload);
// @ts-expect-error Wrong logical payload.
payloads.put(0, 'wrong');
// @ts-expect-error Required opaque argument must still be supplied.
payloads.put(0);
const payloadMap = new api.MapPayloads<object, Payload>(new Map());
payloadMap.put({}, undefined);
const originalMap: Map<object, Payload> = payloadMap.source();
const payloadKey: object | null = payloadMap.key();
// @ts-expect-error Wrong logical key.
payloadMap.has('wrong');
// @ts-expect-error Required opaque key must still be supplied.
payloadMap.has();
const captured: Promise<Payload | null> = payloads.captured(0);
const payloadEvents: AsyncIterableIterator<Payload | null, undefined, undefined> = payloads.events();
const sourceLater: Promise<Payload[]> = payloads.later();
const sourceEvents: AsyncIterableIterator<Payload[], undefined, undefined> = payloads.sources();
const directPayload: Payload | null = direct.stringPayload(new Map<string, Payload>(), 'key');
const externalPayload: Payload | null = external.stringPayload(new Map<string, Payload>(), 'key');
const selectedNumber: number | null = api.keyedScalar(new Map<object, number>(), {});
void [original, saved, nullablePayload, originalMap, payloadKey, captured, payloadEvents, sourceLater, sourceEvents, directPayload, externalPayload, selectedNumber];

const nestedInput = {arrays: [array, null], maps: new Map([['first', map]]), dictionaries: {leaf: array}};
const nestedResult: {arrays: Array<number[] | null>; maps: Map<string, Map<string, number | null> | null>; dictionaries: {[key: string]: number[]}} = api.nested(nestedInput);
const nestedCopy = nestedOnly.nested(external.nested(nestedInput));
const nestedRead: number | null = api.nestedAccess(nestedInput, false);
const nestedValue: api.NestedValue = api.nestedValue({array, map}, []);
const nestedCaptured: number[][] = api.nestedCaptured({first: {trigger: array}, last: array});
const nestedPromise: Promise<typeof nestedResult> = api.nestedLater(nestedInput);
const nestedStream: AsyncIterableIterator<typeof nestedResult, undefined, undefined> = api.nestedEvents(nestedInput);
const nestedPayloads: Payload[][] = api.nestedPayloads<Payload>([[undefined]]);
// @ts-expect-error Nullable handle leaves permit null, not undefined.
api.nested({...nestedInput, arrays: [undefined]});
// @ts-expect-error A handle retains its scalar element declaration.
api.nested({...nestedInput, arrays: [['bad']]});
// @ts-expect-error Dictionary handle leaves are non-null.
api.nested({...nestedInput, dictionaries: {leaf: null}});
// @ts-expect-error Value-class fields use handle types, not arbitrary objects.
api.nestedValue({array: {}, map}, []);
// @ts-expect-error The opaque payload type is retained inside both array layers.
api.nestedPayloads<Payload>([['bad']]);
void [nestedResult, nestedCopy, nestedRead, nestedValue, nestedCaptured, nestedPromise, nestedStream, nestedPayloads];

const innerPayloads: Payload[] = [undefined, {id: 1}];
const liveArrays = new api.NestedArrays<Payload>([innerPayloads, null]);
const liveSource: Array<Payload[] | null> = liveArrays.source();
const liveInner: Payload[] | null = liveArrays.saved();
const liveRead: Promise<Payload | null> = liveArrays.delayedRead(0);
liveArrays.put(0, undefined); liveArrays.same(innerPayloads);
const liveMapSource = new Map<number[], Map<string, Payload | null>>([[array, new Map([['key', undefined]])]]);
const liveMaps = new api.NestedMaps<Payload>(liveMapSource);
const liveMapKey: number[] | null = liveMaps.key();
const liveMapValue: Map<string, Payload | null> | null = liveMaps.value();
liveMaps.putEntry(array, new Map([['key', null]])); liveMaps.put('key', undefined);
const liveNumbers: number[][] = direct.nestedNumbers([[1]]);
const liveBigints: bigint[][] = external.nestedInt64([[1n]]);
const callbackInner: Payload[] | null = api.nestedCallback<Payload>(value => value, [innerPayloads, null]);
const asyncCallbackInner: Promise<Payload[] | null> = external.nestedAsyncCallback<Payload>(async value => value, [innerPayloads, null]);
// @ts-expect-error Nullable child handles permit null, not undefined.
new api.NestedArrays<Payload>([undefined]);
// @ts-expect-error The payload declaration survives both live Array layers.
liveArrays.put(0, 'wrong');
// @ts-expect-error Child Map keys remain numeric Arrays.
new api.NestedMaps<Payload>(new Map([[['wrong'], new Map()]]));
// @ts-expect-error Nested bigint policy requires bigint leaves.
api.nestedInt64([[1]]);
void [liveSource, liveInner, liveRead, liveMapKey, liveMapValue, liveNumbers, liveBigints, callbackInner, asyncCallbackInner];

const ref = new api.RefItem(1), refChild = new api.RefChild(2);
const references = new api.ReferenceCollections([ref, null], new Map([[ref, refChild]]));
const refArray: Array<api.RefItem | null> = references.array();
const refMap: Map<api.RefItem, api.RefItem | null> = references.map();
const readRef: api.RefItem | null = references.read(0);
references.write(0, refChild); references.write(1, null); references.put(ref, refChild);
const refLater: Promise<api.RefItem | null> = references.delayedRead(0);
const nestedRef: api.RefItem | null = api.nestedReference([[ref]]);
const callbackRef: api.RefItem | null = api.referenceCallback(value => value, [ref, null]);
const refBox: api.RefBox<Payload> | null = api.referenceBox<Payload>([new api.RefBox<Payload>(undefined)]);
const intItem = new api.IntItem(7), textItem = new api.TextItem('seven');
const concreteRef: api.TextItem | null = api.concreteReference(new Map([[intItem, textItem]]), intItem);
// @ts-expect-error Reference elements do not permit undefined.
new api.ReferenceCollections([undefined], new Map());
// @ts-expect-error Map keys retain the reference class brand.
new api.ReferenceCollections([], new Map([[new api.OtherItem(1), ref]]));
// @ts-expect-error Structurally similar classes cannot replace a selected reference.
references.write(0, new api.OtherItem(1));
// @ts-expect-error The opaque parameter remains typed inside a reference element.
api.referenceBox<Payload>([new api.RefBox('wrong')]);
// @ts-expect-error Concrete specializations retain distinct class brands.
api.concreteReference(new Map([[intItem, intItem]]), intItem);
void [refArray, refMap, readRef, refLater, nestedRef, callbackRef, refBox, concreteRef];

const resourceItem = new api.ResourceItem(1);
const resourceCollections = new api.ResourceCollections([resourceItem, null], new Map([[resourceItem, null]]));
const resourceArray: Array<api.ResourceItem | null> = resourceCollections.array();
const resourceMap: Map<api.ResourceItem, api.ResourceItem | null> = resourceCollections.map();
const resourceRead: api.ResourceItem | null = resourceCollections.read(0);
resourceCollections.write(0, resourceItem); resourceCollections.put(resourceItem, null);
const resourceUse: Promise<number> = resourceCollections.hold(1, true);
const resourceResult: Promise<Payload> = resourceCollections.result<Payload>(1, undefined);
const resourceStream: AsyncIterableIterator<number, undefined, undefined> = resourceCollections.watch(1);
// @ts-expect-error Resource collection values retain their resource class brand.
new api.ResourceCollections([ref], new Map());
// @ts-expect-error Resource Map keys cannot be ordinary base references.
resourceCollections.has(ref);
// @ts-expect-error Nullable resource elements permit null, not undefined.
resourceCollections.write(0, undefined);
void [resourceArray, resourceMap, resourceRead, resourceUse, resourceResult, resourceStream];

const binary = new api.BinaryCollections([new Uint8Array([1]), null], new Map([['key', new ArrayBuffer(1)]]));
const binaryArray: Array<Uint8Array<ArrayBuffer> | null> = binary.array();
const binaryMap: Map<string, ArrayBuffer | null> = binary.map();
const binaryRead: Uint8Array<ArrayBuffer> | null = binary.read(0);
const binaryBuffer: ArrayBuffer | null = binary.get('key');
binary.write(0, new Uint8Array([2])); binary.put('key', null);
const nestedBytes: Uint8Array<ArrayBuffer> | null = api.nestedBinary([[new Uint8Array([3])]]);
const nestedBuffer: ArrayBuffer | null = api.nestedBuffer([new Map([['key', new ArrayBuffer(1)]])]);
const callbackBytes: Promise<Uint8Array<ArrayBuffer> | null> = api.binaryCallback(async value => value, binaryArray);
const copiedBinaryKey: boolean = api.copiedBinaryKey(new Map([[new Uint8Array([1]), new ArrayBuffer(1)]]));
const nullableBinaryKey: boolean = api.nullableBinaryKey(new Map<Uint8Array<ArrayBuffer> | null, boolean>([[null, false]]));
// @ts-expect-error Uint8List elements use Uint8Array, not another element type.
new api.BinaryCollections([new Uint16Array(1)], new Map());
// @ts-expect-error ByteBuffer values use ArrayBuffer, not a view.
binary.put('key', new Uint8Array(1));
// @ts-expect-error Nullable binary elements accept null, not undefined.
binary.write(0, undefined);
// @ts-expect-error Uint8List keys use Uint8Array, not ArrayBuffer.
api.copiedBinaryKey(new Map([[new ArrayBuffer(1), new ArrayBuffer(1)]]));
void [binaryArray, binaryMap, binaryRead, binaryBuffer, nestedBytes, nestedBuffer, callbackBytes, copiedBinaryKey, nullableBinaryKey];

const sharedBytes = new Uint8Array([1, 2]);
const sharedByteCollections = new api.SharedByteCollections([sharedBytes, null], new Map([[sharedBytes, sharedBytes]]));
const sharedByteArray: Array<Uint8Array<ArrayBuffer> | null> = sharedByteCollections.array();
const sharedByteMap: Map<Uint8Array<ArrayBuffer>, Uint8Array<ArrayBuffer>> = sharedByteCollections.map();
const sharedByteValue: Uint8Array<ArrayBuffer> | null = sharedByteCollections.read(0);
const sharedByteKey: Uint8Array<ArrayBuffer> | null = sharedByteCollections.key();
const distinctPolicies: boolean = api.binarySharedPolicy(sharedByteArray, sharedByteArray);
// @ts-expect-error Shared view keys require Uint8Array, not ArrayBuffer.
new api.SharedByteCollections([], new Map([[new ArrayBuffer(1), sharedBytes]]));
// @ts-expect-error Nullable shared elements permit null, not undefined.
new api.SharedByteCollections([undefined], new Map());
void [sharedByteArray, sharedByteMap, sharedByteValue, sharedByteKey, distinctPolicies];

const structuralItem: {text: string; values: Array<number | null>; bytes: Map<string, Uint8Array<ArrayBuffer> | null>; shared: {[key: string]: Uint8Array<ArrayBuffer> | null}} = {text: 'x', values: [1, null], bytes: new Map([['key', new Uint8Array([2])]]), shared: {key: sharedBytes}};
const structuralCollections = new api.StructuralCollections([structuralItem, null], new Map([['key', structuralItem]]));
const structuralArray: Array<typeof structuralItem | null> = structuralCollections.array();
const structuralMap: Map<string, typeof structuralItem | null> = structuralCollections.map();
const structuralRead = structuralCollections.read(0);
const structuralCopiedKeys: boolean = api.structuralKeys(new Map([[[1], {value: 2}]]));
const structuralRecordKey: number[] | null = api.recordKey(new Map([[{id: 1}, [2]]]));
const structuralContainerKeys: boolean = api.containerKeys(new Map([[new Map([['key', 1]]), {value: 2}]]), new Map([[{key: 1}, [2]]]));
const structuralCollision: boolean = api.recordMapCollision([new Map([[{id: 1}, 1]])], true);
const structuralWide: bigint[][] = api.structuralBigints([[1n]]);
const structuralArbitrary: bigint[][] = api.structuralWideBigints([[1n << 130n]]);
const structuralResourceEntry: number = api.mixedResourceEntries(new Map([[resourceItem, [1]]]));
const structuralCallbackValue: number[] | null = api.structuralCallback(value => value, [[1]]);
// @ts-expect-error Deep copied elements preserve scalar precision policy types.
api.structuralBigints([[1]]);
// @ts-expect-error Nested record fields remain required.
new api.StructuralCollections([{values: []}], new Map());
// @ts-expect-error Copy keys retain their declared List element type.
api.structuralKeys(new Map([[['wrong'], {value: 1}]]));
void [structuralArray, structuralMap, structuralRead, structuralCopiedKeys, structuralRecordKey, structuralContainerKeys, structuralCollision, structuralWide, structuralArbitrary, structuralResourceEntry, structuralCallbackValue];

const copiedPayloadSource = [{reference: ref, payload: undefined as Payload, handle: [undefined] as Payload[]}];
const copiedPayloads = new api.CopiedPayloads<Payload>(copiedPayloadSource);
const copiedPayload: Payload | null = copiedPayloads.payload();
const copiedHandle: Payload[] | null = copiedPayloads.handle();
const copiedReference: api.RefItem | null = copiedPayloads.reference();
const pureCopied: Payload[][] = copiedOnly.pureCopiedPayload<Payload>([[undefined]]);
const copiedResources = new api.CopiedResources([{resource: resourceItem, values: [1]}]);
const copiedResourceUse: Promise<number> = copiedResources.hold(1);
// @ts-expect-error Nested opaque payloads retain their logical type.
new api.CopiedPayloads<Payload>([{reference: ref, payload: 'wrong', handle: []}]);
void [copiedPayload, copiedHandle, copiedReference, pureCopied, copiedResourceUse];
