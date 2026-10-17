import * as api from '@napi/opaque-fixture';
import * as direct from '@napi/opaque-fixture/BACKEND';
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
