import * as api from '@napi/concrete-fixture';
import * as direct from '@napi/concrete-fixture/BACKEND';
import * as external from '@napi/concrete-external';
const integer = new api.IntCell(7);
const decimal = new api.DoubleCell(1.5);
const same: api.IntCell = api.equivalent(integer);
const named: api.IntCell = api.IntCell.named(9);
const adopted: api.IntCell = api.createInt(21);
const number: number = integer.value;
const self: api.IntCell = integer.self();
const nested: Map<string, number | null>[] = integer.nested();
const asyncNumber: Promise<number> = integer.futureValue();
const asyncCell: Promise<api.IntCell> = api.delayedInt(integer);
const stream: AsyncIterableIterator<number> = integer.values();
const list: (api.IntCell | null)[] = api.listCells([integer, null]);
const map: Map<api.IntCell, api.DoubleCell> = api.mapCells(new Map([[integer, decimal]]));
const pair: {first: api.IntCell, second: api.DoubleCell} = api.pair({first: integer, second: decimal});
const nullable = new api.NullableCell(null);
nullable.value = 2;
const batch = new api.BatchCell([new Map<string, number | null>([['a', 1], ['b', null]])]);
const leaf = new api.Leaf(1), leaves = new api.LeafCell(leaf);
const returnedLeaf: api.Leaf = leaves.value;
const directCell: api.IntCell = new direct.IntCell(1);
const selected: external.IntCell = new external.IntCell(1);
integer.optional(); integer.optional(null); integer.optional(undefined);
integer.namedOptional(); integer.namedOptional({next: null});
// @ts-expect-error Concrete aliases have no free logical type parameter.
new api.IntCell<string>('wrong');
// @ts-expect-error Concrete types have distinct nominal handle identities despite both mapping to number.
api.echoInt(decimal);
// @ts-expect-error Wrong concrete class cannot be assigned through identical structural fields.
const wrong: api.IntCell = decimal;
// @ts-expect-error Nullable specialization is a different runtime class identity.
api.echoInt(nullable);
// @ts-expect-error Required nullable value is not optional.
new api.NullableCell();
// @ts-expect-error Nullability does not add undefined to a required parameter.
new api.NullableCell(undefined);
// @ts-expect-error References keep concrete identity inside containers.
api.listCells([decimal]);
// @ts-expect-error References keep concrete identity in map keys and values.
api.mapCells(new Map([[decimal, integer]]));
// @ts-expect-error A leaf specialization contains Leaf, not arbitrary reference objects.
new api.LeafCell(integer);
// @ts-expect-error Closed nested substitutions remain typed.
new api.BatchCell([new Map([['bad', 'wrong']])]);
// @ts-expect-error Ordinary constructor retains scalar requirements.
new api.IntCell('7');
void [same, named, adopted, number, self, nested, asyncNumber, asyncCell, stream, list, map, pair, batch, returnedLeaf, directCell, selected, wrong];

const session = new api.IntSession(1, 7);
const decimalSession = new api.DoubleSession(2, 1.5);
const nullableSession = new api.NullableSession(3, null);
const sessionCopy: api.IntSession = api.IntSession.from(4, 8);
const sessionSelf: api.IntSession = session.self();
const sessionValue: Promise<number> = session.futureValue();
const heldSession: Promise<number> = api.holdSessions([session], 1);
const resourceStream: AsyncIterableIterator<number> = session.watch(2);
const closeSession: Promise<void> = session.close(undefined, () => {});
const closeNullable: Promise<void> = nullableSession.shutdown({fail: false});
const closeVoid: Promise<void> = new api.VoidSession(4).close();
const ordinaryClose: void = nullableSession.close();
// @ts-expect-error Different concrete resources retain distinct handle identities.
api.echoSession(decimalSession);
// @ts-expect-error Covariance does not grant the narrower resource handle.
api.echoSession(nullableSession);
// @ts-expect-error Concrete resource type arguments are already fixed.
new api.IntSession<string>(5, 'value');
// @ts-expect-error Concrete integer payload is not a string.
new api.IntSession(5, 'value');
// @ts-expect-error Resource identity remains checked within structural inputs.
api.holdSessions([decimalSession], 1);
// @ts-expect-error Required nullable resource value is not optional.
new api.NullableSession(6);
// @ts-expect-error Required nullable resource value does not accept undefined.
new api.NullableSession(6, undefined);
void [sessionCopy, sessionSelf, sessionValue, heldSession, resourceStream, closeSession, closeNullable, closeVoid, ordinaryClose];

const textSession: api.NullableTextSession = api.createTextSession(7, 'text');
const sessionProjection: api.TextSessionValue = api.projectTextSession(textSession);
const sessionProjectionFuture: Promise<api.TextSessionValue> = api.delayedTextSession(textSession, 7);
const sessionData: api.TextSessionValue = api.echoTextSessionValue({id: 8, value: 'data'});
const externalSessionData: external.TextSessionValue = external.projectTextSession(external.createTextSession(9, 'external'));
// @ts-expect-error The value specialization has no JavaScript constructor.
new api.TextSessionValue(7, 'text');
// @ts-expect-error A structural projection is not a resource handle.
api.projectTextSession(sessionProjection);
// @ts-expect-error Nullable resource fields do not satisfy the concrete value input.
api.echoTextSessionValue(textSession);
// @ts-expect-error Resource cleanup is not part of the projected value schema.
sessionProjection.close();
void [sessionProjectionFuture, sessionData, externalSessionData];

const concreteValue: api.IntValue = api.echoIntValue({value: 1, next: {value: 2}});
const requiredNext: api.IntValue | null = concreteValue.next;
const valueTuple: {$1: api.IntValue; $2: api.TextValue; $3: api.DoubleValue} = api.valueTuple({$1: {value: 1}, $2: {value: 'two'}, $3: {value: 1.5}});
const nestedValue: api.NestedValue = api.nestedValue({value: {value: 1}});
const nullableValue: api.NullableValue | null = api.nullableValue({value: null});
const valueReference: api.Leaf = api.leafValue({value: leaf}).value;
const valueBytes: Uint8Array<ArrayBuffer> = api.bytesValue({value: new Uint8Array([1])}).value;
const valueShared: Uint8Array<ArrayBuffer> = api.sharedValue({value: new Uint8Array([1])}).value;
const parsed: number = api.parseInteger({value: '1'}).value;
const typedFuture: Promise<api.IntValue> = api.delayedValue({value: 1});
const typedStream: AsyncIterableIterator<api.IntValue> = api.valueEvents();
const typedWide: bigint = api.bigintValue({value: 1n, next: {value: 2n}}).value;
const copiedDirect: api.IntValue = direct.echoIntValue({value: 1});
const externalValue: external.TextValue = external.valueTuple({$1: {value: 1}, $2: {value: 'two'}, $3: {value: 3}}).$2;
api.echoIntValue({value: 1, tag: undefined, next: undefined});
// @ts-expect-error A concrete value alias is a data type, without a JS constructor.
new api.IntValue(1);
// @ts-expect-error A concrete value alias has no free type argument.
const freeValue: api.IntValue<string> = concreteValue;
// @ts-expect-error Different specializations retain their field types within one root.
api.valueTuple({$1: {value: 1}, $2: {value: 2}, $3: {value: 3}});
// @ts-expect-error Output-only derived properties are not accepted input fields.
api.echoIntValue({value: 1, isInt: true});
// @ts-expect-error Public value output fields remain required.
const incompleteValue: api.IntValue = {value: 1};
// @ts-expect-error Nested specialization uses its own input schema.
api.nestedValue({value: {value: 'wrong'}});
// @ts-expect-error Required nullable leaves do not accept undefined.
api.nullableValue({value: undefined});
// @ts-expect-error Constructor input type differs from getter output type.
api.parseInteger({value: 1});
// @ts-expect-error Plain value input cannot masquerade as a handle of the same origin.
api.echoValueHandle({value: 1});
// @ts-expect-error Ordinary integer mode does not accept bigint.
api.echoIntValue({value: 1n});
void [concreteValue, requiredNext, valueTuple, nestedValue, nullableValue, valueReference, valueBytes, valueShared, parsed, typedFuture, typedStream, typedWide, copiedDirect, externalValue, freeValue, incompleteValue];

const hiddenValueType: api.Leaf = api.valueShadow<string>({value: leaf}, 'payload').value;
void hiddenValueType;

const child = new api.IntChildCell(1);
const parent: api.IntCell = child;
const feature: api.IntCellFeature = child;
const childSelf: api.IntChildCell = child.self();
const featureResult: number = feature.feature(1);
const childDefault: number = child.count();
const adoptedChild: api.IntCell = api.createChildCell(2);
const batchChild: api.IntListCell = new api.IntBatchChild([1, 2]);
const childSession: api.IntSession = new api.IntChildSession(503, 1);
const childCleanup: Promise<void> = childSession.close();
const externalChild: external.IntCell = new external.IntChildCell(3);
// @ts-expect-error Same JS scalar representation does not merge generic parents.
const wrongChild: api.IntCell = new api.DoubleChildCell(1.5);
// @ts-expect-error Covariance is not a selected wider writable view.
const widerChild: api.NullableCell = child;
// @ts-expect-error A base object does not have the nominal child identity.
const reverseChild: api.IntChildCell = new api.IntCell(1);
// @ts-expect-error Interface specializations retain nominal identity.
const wrongFeature: api.IntCellFeature = new api.DoubleChildCell(1.5);
// @ts-expect-error Named constructors are not inherited as static APIs.
api.IntChildCell.named(1);
// @ts-expect-error Nested substitution does not accept strings.
new api.IntBatchChild(['wrong']);
// @ts-expect-error Resource inheritance does not erase concrete parameters.
api.echoSession(new api.DoubleChildSession(504, 1.5));
void [parent, feature, childSelf, featureResult, childDefault, adoptedChild, batchChild, childCleanup, externalChild, wrongChild, widerChild, reverseChild, wrongFeature];

const nullableChild: api.NullableCell = new api.NullableChildCell(null);
// @ts-expect-error A selected child specialization does not widen another child's boundary identity.
const widerChildInstance: api.NullableChildCell = child;
void [nullableChild, widerChildInstance];

const deepCell: api.IntCell = new api.DeepCell(1);
const mixedDeepCell: api.IntCell = api.createMixedDeepCell(2);
const deepSession: api.IntSession = new api.DeepSession(520, 1);
const deepCleanup: Promise<void> = deepSession.close();
const directDeepCleanup: Promise<void> = new api.DeepSession(524, 1).close();
void directDeepCleanup;
const mixedDeepSession: api.IntSession = api.createMixedDeepSession(521, 2);
// @ts-expect-error The selected wider intermediate is not an ancestor view.
const wideMiddle: api.NullableMiddleCell = new api.DeepCell(1);
// @ts-expect-error The wider resource view has a different type and cleanup policy.
const wideSessionMiddle: api.NullableMiddleSession = new api.DeepSession(522, 2);
void [deepCell, mixedDeepCell, deepCleanup, mixedDeepSession, wideMiddle, wideSessionMiddle];

const hiddenCell: api.NullableMiddleCell = api.createHiddenMiddleCell(3);
const hiddenParent: api.NullableCell = hiddenCell;
const hiddenSession: api.NullableSession = api.createHiddenSession(523, 3);
const hiddenCleanup: Promise<void> = hiddenSession.shutdown();
// @ts-expect-error The accepted selected child carries its wider ancestor view.
const hiddenNarrowParent: api.IntCell = hiddenCell;
void [hiddenParent, hiddenCleanup, hiddenNarrowParent];

const compatibleView: api.NullableCrossView = api.compatibleView();
const compatibleOwner: api.NullableCrossOwner = api.compatibleOwner(524);
const compatibleCleanup: Promise<void> = compatibleOwner.close();
// @ts-expect-error Same-origin concrete aliases remain invariant through children.
const wrongCrossParent: api.IntCrossView = api.compatibleView();
void [compatibleView, compatibleCleanup, wrongCrossParent];
