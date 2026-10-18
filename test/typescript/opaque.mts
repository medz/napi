import * as api from '@napi/opaque-fixture';
import * as direct from '@napi/opaque-fixture/BACKEND';
import * as namedExternal from '@napi/opaque-external';
import {plainEcho, plainFuture, PlainStore, SetterThenBox as ExternalSetterThenBox} from '@napi/opaque-external';

const item = {name: 'payload'};
const same: typeof item = api.identity(item);
const un: undefined = api.identity(undefined);
const nullable: null = api.identity(null);
const directValue: symbol = direct.identity(Symbol('direct'));
const router = new api.Router<string>();
router.set('key', 'value');
router.put({key: 'named', value: 'value'});
const read: string | null = router.get('key');
const sameRouter: api.Router<string> = router.self();
const forwarded: api.Router<string> = api.forwardRouter(router);
const readopted: api.Router<string> = api.readoptRouter<string>();
router.value = 'field';
router.value = null;
const optional: string | null = router.optional();
router.optional('value');
router.optional(null);
const unknown = new api.Router();
unknown.set('anything', undefined);
unknown.set('anything', item);
const nullish = new api.Router<string | null | undefined>();
nullish.put({key: 'undefined', value: undefined});
nullish.put({key: 'null', value: null});
const named: api.Router<string> = api.Router.withValue('initial');
const pair = new api.Pair('first', 42);
const first: string = pair.first;
const second: number = pair.second;
const boundedNull = new api.Bounded<null>(null);
const boundedUndefined = new api.Bounded<undefined>(undefined);
const output: string | null = api.optional<string>();
api.optional<string>('value');
api.optional<string>(null);
api.optional<undefined>(undefined);
api.prefix<string>();
api.prefix<string>('first', undefined);
api.prefix<string>('first', 0, 'last');
api.prefix<string | undefined>(undefined, 0, undefined);
const pending: Promise<number> = api.waitOpaque(item);
const external: typeof item = plainEcho(item);
const store = new PlainStore('value');
const stored: string = store.value;
const array: number[] = api.opaqueArray('payload');
const emptyRecord: Record<PropertyKey, never> = api.opaqueRecord(undefined);
const emptyKey: Record<PropertyKey, never> = api.opaqueKey(null);
const globalResult: Promise<Map<string, number>> = api.opaqueGlobal(Symbol());

const numbers: number[] = new api.Array('payload').numbers();
const empty: Record<PropertyKey, never> = new api.Record().empty();
const futureRouter: Promise<api.Router<string>> = api.futureRouter(router);
void [numbers, empty, futureRouter];

const futurePayload: Promise<typeof item> = api.futureIdentity(item);
const futureUndefined: Promise<undefined> = api.futureIdentity(undefined);
const futureNull: Promise<null> = api.futureIdentity(null);
const futureMissing: Promise<string | null> = api.futureOptional<string>();
const futureSupplied: Promise<undefined | null> = api.futureOptional<undefined>(undefined);
const futureRead: Promise<string | null> = router.futureGet('key');
const futureField: Promise<string | null> = router.futureValue;
const promised: Promise<number> = api.futureIdentity(Promise.resolve(42));
const thenable = {then(resolve: (value: number) => void) { resolve(42); }};
const adopted: Promise<number> = api.futureIdentity(thenable);
const box = new api.ThenBox(thenable.then);
const boxFuture: Promise<number> = box.futureSelf();
const boxForward: Promise<number> = api.futureThenBox(box);
const boxNested: Promise<api.ThenBox<typeof thenable.then>[]> = api.futureIdentity([box]);
const nullableThen = new api.ThenBox<typeof thenable.then | null>(null);
const nullableAdopted: Promise<number | typeof nullableThen> = nullableThen.futureSelf();
const unknownThen = new api.ThenBox<unknown>(undefined);
const unknownResult: Promise<unknown> = api.futureThenBox(unknownThen);
const noncallableThen = new api.ThenBox('not callable');
const noncallableResult: Promise<typeof noncallableThen> = noncallableThen.futureSelf();
const shadowed: Promise<symbol> = api.opaqueAwaited(Symbol());
const awaitedStore = new api.Awaited('value');
const awaitedStored: Promise<api.Awaited<string>> = api.futureIdentity(awaitedStore);
const externalFuture: Promise<number> = plainFuture(thenable);
const storedFuture: Promise<string> = store.futureValue();

// @ts-expect-error Future validation preserves required input presence.
api.futureIdentity();
// @ts-expect-error Supplied undefined is not string, even for an optional Future input.
api.futureOptional<string>(undefined);
// @ts-expect-error Promise results adopt the thenable instead of preserving its root type.
const wrongAdopted: Promise<typeof thenable> = api.futureIdentity(thenable);
// @ts-expect-error A selected then member also participates in Promise resolution.
const wrongBox: Promise<typeof box> = box.futureSelf();
// @ts-expect-error A nullable then can still be callable at runtime.
const wrongNullable: Promise<typeof nullableThen> = nullableThen.futureSelf();
// @ts-expect-error Unknown then values cannot promise the original wrapper.
const wrongUnknown: Promise<typeof unknownThen> = api.futureThenBox(unknownThen);
void [futurePayload, futureUndefined, futureNull, futureMissing, futureSupplied,
  futureRead, futureField, promised, adopted, boxFuture, boxForward, boxNested,
  nullableAdopted, unknownResult, noncallableResult, shadowed, awaitedStored,
  externalFuture, storedFuture, wrongAdopted, wrongBox, wrongNullable, wrongUnknown];

// @ts-expect-error A required opaque argument may be undefined, but cannot be omitted.
api.identity();
// @ts-expect-error Fixed T preserves the declared payload relationship.
api.identity<string>(undefined);
// @ts-expect-error Optional opaque omission does not accept a supplied undefined for string T.
api.optional<string>(undefined);
// @ts-expect-error Class optional opaque inputs use the same presence rule.
router.optional(undefined);
// @ts-expect-error Prefix overloads preserve each supplied opaque argument.
api.prefix<string>(undefined);
// @ts-expect-error The last supplied opaque slot also preserves T.
api.prefix<string>('first', 0, undefined);
// @ts-expect-error A required named payload property cannot be omitted.
router.put({key: 'missing'});
// @ts-expect-error This property contains string T, not undefined, with either exact-optional setting.
router.put({key: 'wrong', value: undefined});
// @ts-expect-error Mutable generic storage cannot be widened unsafely.
const widened: api.Router<string | number> = router;
// @ts-expect-error Narrowing mutable storage is unsafe too.
const narrowed: api.Router<string> = new api.Router<string | number>();
// @ts-expect-error The mutable field also retains logical T.
router.value = 42;
// @ts-expect-error There is no synthesized undefined in the optional field's value type.
router.value = undefined;
// @ts-expect-error The private invariant marker rejects structural impostors.
const fake: api.Router<string> = {};
// @ts-expect-error The original first declaration parameter remains string.
pair.first = 42;
// @ts-expect-error The original second type parameter remains number.
pair.second = 'wrong';
// @ts-expect-error External generic declarations retain the same relationship.
store.value = 42;
// @ts-expect-error An external generic constructor requires its payload.
new PlainStore<string>();
void [same, un, nullable, directValue, read, sameRouter, forwarded, readopted,
  optional, named, first, second, boundedNull, boundedUndefined, output, pending,
  external, stored, array, emptyRecord, emptyKey, globalResult, widened, narrowed, fake];

const setterOnly = new api.SetterThenBox(thenable.then);
const setterRead: unknown = setterOnly.then;
setterOnly.then = thenable.then;
const setterPromise: Promise<unknown> = setterOnly.futureSelf();
const setterOpaque: Promise<unknown> = api.futureIdentity(setterOnly);
// @ts-expect-error A composed getter can produce an unknown fulfillment value.
const wrongSetter: Promise<number> = setterOnly.futureSelf();
void [setterRead, setterPromise, setterOpaque, wrongSetter];

api.StaticSetterThenBox.then = () => {};
const staticSetterRead: undefined = api.StaticSetterThenBox.then;
const staticSetterPromise: Promise<typeof api.StaticSetterThenBox> = api.futureIdentity(api.StaticSetterThenBox);
// @ts-expect-error Reading static setter-only then must not assimilate its callback input.
const wrongStaticSetter: Promise<never> = api.futureIdentity(api.StaticSetterThenBox);
// @ts-expect-error An independent undefined read must preserve the setter input type.
api.StaticSetterThenBox.then = 'wrong';
void [staticSetterRead, staticSetterPromise, wrongStaticSetter];

const composite = api.compositeThen(thenable.then);
const compositeRead: unknown = composite.then;
const compositeFuture: Promise<unknown> = composite.futureSelf();
// @ts-expect-error Unselected implementations can add compatible getter views.
const wrongCompositeRead: undefined = composite.then;
// @ts-expect-error A composed then getter can assimilate instead of preserving the wrapper.
const wrongCompositeFuture: Promise<typeof composite> = composite.futureSelf();
const isolatedSetter = new ExternalSetterThenBox(thenable.then);
isolatedSetter.then = thenable.then;
const isolatedRead: undefined = isolatedSetter.then;
const isolatedSelf: Promise<typeof isolatedSetter> = isolatedSetter.futureSelf();
const isolatedOpaque: Promise<typeof isolatedSetter> = plainFuture(isolatedSetter);
// @ts-expect-error A setter without a possible getter never assimilates its input type.
const wrongIsolated: Promise<number> = isolatedSetter.futureSelf();
// @ts-expect-error Exact read typing still preserves setter input validation.
isolatedSetter.then = 'wrong';
void [compositeRead, compositeFuture, wrongCompositeRead, wrongCompositeFuture,
  isolatedRead, isolatedSelf, isolatedOpaque, wrongIsolated];

// Optional named properties use ordinary TypeScript optional-field semantics.
const namedOutput: string | null = api.named<string>(7);
api.named<string>(7, undefined);
api.named<string>(7, {});
api.named<string>(7, {first: 'first', second: null, choose: undefined});
api.named<string | undefined>(0, {first: undefined, second: undefined});
api.mixedRequired<string>({first: 'required'});
api.mixedRequired<string | undefined>({first: undefined, second: undefined});
const namedFuture: Promise<string | null> = api.futureNamed<string>(7, {second: 'second'});
const namedAdopted: Promise<number | null> = api.futureNamed(0, {second: thenable});
const namedStore = new api.NamedStore<string>();
new api.NamedStore<string>(undefined);
new api.NamedStore<string>({});
const namedStored: string | null = namedStore.first;
const namedSecond: string | null = namedStore.second;
const markedStore: api.NamedStore<string> = api.NamedStore.withMarker<string>(9, {first: null, second: 'second'});
const namedSelection: string | null = namedStore.select(7, {});
const namedSelectedFuture: Promise<string | null> = namedStore.futureSelect(0, {second: 'second'});
const undefinedStore = new api.NamedStore<string | undefined>({first: undefined, second: undefined});
undefinedStore.select(7, {first: undefined});
const undefinedFuture: Promise<string | null | undefined> = undefinedStore.futureSelect(0, {second: undefined});
const externalNamed: string | null = namedExternal.named<string>(7, {});
const externalNamedFuture: Promise<string | null> = namedExternal.futureNamed<string>(0, {second: 'second'});
const externalNamedStore = new namedExternal.NamedStore<string>({first: 'first'});
const externalMarked: namedExternal.NamedStore<string> = namedExternal.NamedStore.withMarker<string>(9);
const directNamed: string | null = direct.named<string>(7, {first: 'first'});

// @ts-expect-error A required positional argument stays required before options.
api.named<string>();
// @ts-expect-error Required named properties remain required in both optional modes.
api.mixedRequired<string>();
// @ts-expect-error An empty object does not satisfy the required named payload.
api.mixedRequired<string>({});
// @ts-expect-error A required opaque field does not admit undefined for string T.
api.mixedRequired<string>({first: undefined});
// @ts-expect-error Named fields retain T instead of becoming unknown.
api.named<string>(7, {second: 42});
// @ts-expect-error Options must be an object or omitted, not null.
new api.NamedStore<string>(null);
// @ts-expect-error Named constructor positional presence is independent of its options.
api.NamedStore.withMarker<string>();
// @ts-expect-error Omission changes the parameter shape, not the stored value type.
namedStore.first = undefined;
// @exact-optional-error
api.named<string>(7, {first: undefined});
// @exact-optional-error
api.named<string>(0, {second: undefined});
// @exact-optional-error
api.mixedRequired<string>({first: 'required', second: undefined});
// @exact-optional-error
new api.NamedStore<string>({first: undefined, second: undefined});
// @exact-optional-error
api.NamedStore.withMarker<string>(9, {second: undefined});
// @exact-optional-error
namedStore.select(7, {first: undefined});
// @exact-optional-error
namedStore.futureSelect(0, {second: undefined});
// @exact-optional-error
api.futureNamed<string>(7, {first: undefined});
// @exact-optional-error
namedExternal.named<string>(7, {first: undefined});
// @exact-optional-error
externalNamedStore.select(0, {second: undefined});
const undefinedOptions = {first: undefined, second: undefined};
api.named<string | undefined>(7, undefinedOptions);
// @exact-optional-error
api.named<string>(7, undefinedOptions);
const optionalPayload: {first?: string | undefined} = {first: undefined};
namedExternal.named<string | undefined>(7, optionalPayload);
// @exact-optional-error
namedExternal.named<string>(7, optionalPayload);
void [namedOutput, namedFuture, namedAdopted, namedStored, namedSecond, markedStore,
  namedSelection, namedSelectedFuture, undefinedFuture, externalNamed,
  externalNamedFuture, externalMarked, directNamed];


const inherited = new api.OpaqueChild<{tag: string}>({tag: 'child'});
const inheritedBase: api.OpaqueBase<{tag: string}> = inherited;
const inheritedRead: {tag: string} = inherited.read();
const inheritedSelf: api.OpaqueChild<{tag: string}> = inherited.self();
const inheritedPromise: Promise<{tag: string}> = inherited.later();
const inheritedStream: AsyncIterableIterator<{tag: string}> = inherited.values();
const inheritedDirect: direct.OpaqueBase<{tag: string}> = inherited;
const inheritedExternal = new namedExternal.OpaqueChild<string>('external');
const inheritedExternalBase: namedExternal.OpaqueBase<string> = inheritedExternal;
const permuted = new api.OpaquePairChild<string, number>(7, 'second');
const mapped: api.OpaquePair<number, string> = permuted;
const mappedSlot: api.OpaqueSlot<number, string> = permuted;
const mappedResult: api.OpaquePair<number, string> = api.opaqueAsPair(permuted);
const mappedFirst: number = permuted.first;
const mappedSecond: string = permuted.second;
const mappedGetter: string = permuted.slot;
permuted.slot = 'replacement';
const transitive = new api.OpaqueLeaf<number, string>(7, 'second');
const transitiveBase: api.OpaquePair<number, string> = transitive;
const thenChild = new api.OpaqueThenChild((resolve: (value: number) => void) => resolve(72));
const inheritedThenable: Promise<number> = thenChild.later();
// @ts-expect-error a permutation cannot be silently reordered
const incorrectOrder: api.OpaquePair<string, number> = permuted;
// @ts-expect-error inherited generic mutable handles are invariant
const incorrectWiden: api.OpaqueBase<{tag: string} | null> = inherited;
// @ts-expect-error invariance also applies to permuted ancestors
const incorrectPairWiden: api.OpaquePair<number | null, string> = permuted;
// @ts-expect-error parent handles cannot forge the child brand
const incorrectChild: api.OpaqueChild<string> = new api.OpaqueBase('base');
// @ts-expect-error separately loaded modules retain nominal reference brands
const incorrectModule: api.OpaqueBase<string> = inheritedExternal;
// @ts-expect-error inherited optional opaque input still requires supplied payload type
inherited.optional(undefined);
// @ts-expect-error the interface getter/setter use the projected child parameter
permuted.slot = 7;
void [inheritedBase, inheritedRead, inheritedSelf, inheritedPromise, inheritedStream,
  inheritedDirect, inheritedExternalBase, mapped, mappedSlot, mappedResult,
  mappedFirst, mappedSecond, mappedGetter, transitiveBase, inheritedThenable];

const inheritedWriter = new api.OpaqueWrite<string>();
const possibleInheritedRead: string | null | undefined = inheritedWriter.part;
const inheritedReader = new api.OpaqueRead<string>();
inheritedReader.part = 'payload';
const definiteInheritedRead: string | null = inheritedReader.part;
// @ts-expect-error inherited setter retains the parent payload type
inheritedReader.part = 7;
void [possibleInheritedRead, definiteInheritedRead];

const nullableInherited = new api.OpaqueChild<string | null>(null);
// @ts-expect-error inherited invariant view cannot narrow nullability either
const narrowedInherited: api.OpaqueBase<string> = nullableInherited;
// @ts-expect-error same-origin generic handles stay invariant
const widerInherited: api.OpaqueChild<string | null> = new api.OpaqueChild('value');


const inheritedArray: number[] = permuted.writeArray([], 9);
const overriddenMap: Map<number, string> = permuted.writeMap(new Map(), 9, 'value');
const leafArray: number[] = transitive.writeArray([], 9);
const leafMap: Map<number, string> = transitive.writeMap(new Map(), 9, 'value');
const externalPair = new namedExternal.OpaquePairChild<string, number>(7, 'external');
const externalArray: number[] = externalPair.writeArray([], 9);
const externalMap: Map<number, string> = externalPair.writeMap(new Map(), 9, 'value');
const directPair: direct.OpaquePair<number, string> = permuted;
const directMap: Map<number, string> = directPair.writeMap(new Map(), 9, 'value');
const undefinedPair = new api.OpaquePairChild<string | undefined, number | undefined>(undefined, undefined);
undefinedPair.writeArray([], undefined);
undefinedPair.writeMap(new Map(), undefined, undefined);
// @ts-expect-error Inherited handle elements follow the permuted parent parameter.
permuted.writeArray(['wrong'], 9);
// @ts-expect-error Inherited opaque input requires presence.
permuted.writeArray([]);
// @ts-expect-error The child override preserves the permuted map key.
permuted.writeMap(new Map(), 'wrong', 'value');
// @ts-expect-error The child override preserves the permuted map value.
permuted.writeMap(new Map(), 9, 12);
// @ts-expect-error Opaque values may contain undefined but cannot be omitted.
undefinedPair.writeMap(new Map(), undefined);
// @ts-expect-error Transitive permutation preserves the map key and value order.
transitive.writeMap(new Map<string, number>(), 9, 'value');
void [inheritedArray, overriddenMap, leafArray, leafMap, externalArray, externalMap, directMap];
