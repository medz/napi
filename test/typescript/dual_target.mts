import * as root from '@napi/dual-fixture';
import * as native from '@napi/dual-fixture/native';
import * as wasm from '@napi/dual-fixture/wasm';
import * as direct from '@napi/dual-fixture/module.wasm';
import * as nativeRoot from '@napi/dual-external';
import * as selectedNative from '@napi/dual-external/native';
import type {Row} from '@napi/dual-fixture';

const inputRow = {label: 'row', values: [1, 2]} as const;
const row: Row = root.appendRow(inputRow);
const nativeRow: native.Row = native.appendRow(inputRow);
const wasmRow: wasm.Row = wasm.appendRow(inputRow);
const externalRow: selectedNative.Row = nativeRoot.appendRow(inputRow);
for (const value of [row, nativeRow, wasmRow, externalRow]) value.values.push(4);
// @ts-expect-error Readonly inputs retain their element type.
root.appendRow({label: 'row', values: ['bad']} as const);
// @ts-expect-error The public record type retains required fields.
const missingRow: Row = {label: 'row'};
void missingRow;

const a: wasm.Counter = new root.Counter();
const b: direct.Counter = a;
root.identity(b);
const c: selectedNative.Counter = new nativeRoot.Counter();
nativeRoot.identity(c);
const n: number = native.add(1);
const future: Promise<number> = wasm.later(n);
const stream: AsyncIterableIterator<number, undefined, undefined> = root.sequence(n);
const closed: Promise<void> = new native.Resource(1).close();
const v: void = native.reset();
void [future, stream, closed, v];
// @ts-expect-error Runtime owners differ even though their API text is identical.
native.identity(a);
// @ts-expect-error Resource owners also differ.
const resource: native.Resource = new wasm.Resource(1);
// @ts-expect-error Required argument.
wasm.add();
// @ts-expect-error Wrong scalar.
native.add('1');
// @ts-expect-error Unknown named option.
root.format('x', {unknown: true});
// @ts-expect-error Instances require genuine reference brands.
wasm.identity({value: 1, increment: () => 1});

const defaults: boolean = wasm.structuralDefaults(undefined, new Map([['a', [1, null]]]));
const namedDefault: boolean = native.namedDefaults({wide: undefined});
const defaultObject = new root.DefaultBase(undefined);
const defaultNamed: root.DefaultBase = root.DefaultBase.named({});
const inherited: Promise<boolean> = new root.DefaultChild().later();
void [defaults, namedDefault, defaultObject, defaultNamed, inherited];
// @ts-expect-error Non-null structural defaults do not make null a valid input.
wasm.structuralDefaults(null);
// @ts-expect-error Supplied lists still use their scalar contract.
native.namedDefaults({wide: [1n]});

const objectDefaults: boolean = wasm.objectDefaults(undefined, {});
const token: native.DefaultToken = native.objectDefaultToken(undefined);
const sameToken: boolean = native.namedObjectDefault({token});
const nullableToken: boolean = native.namedObjectDefault({token: null});
const objectValue: wasm.DefaultValue = wasm.objectDefaultValue({value: undefined});
const fieldDefault: boolean = wasm.valueFieldDefault({token: undefined});
const concreteDefault: boolean = wasm.genericObjectDefault(new wasm.DefaultIntBox(13));
const factoryDefault: boolean = native.factoryObjectDefault(new native.DefaultProjection(17));
const afterHole: number = root.objectDefaultAfter(undefined, 0);
const objectBase: root.DefaultBase = root.DefaultBase.namedObject({value: undefined});
const inheritedObject: Promise<boolean> = new root.DefaultChild().laterObject({});
const externalDefault: boolean = nativeRoot.objectDefaults(undefined, {value: 9});
void [objectDefaults, sameToken, nullableToken, objectValue, fieldDefault,
  concreteDefault, factoryDefault, afterHole, objectBase, inheritedObject, externalDefault];
// @ts-expect-error Reference defaults retain their nominal input type.
wasm.objectDefaultToken({value: 7});
// @ts-expect-error Non-null defaults do not permit null.
native.objectDefaults(null);
// @ts-expect-error The concrete class retains its selected integer type.
new wasm.DefaultIntBox('13');
// @ts-expect-error Structural value fields retain reference ownership.
wasm.valueFieldDefault({token});

const constResource: wasm.ConstResource = wasm.resourceDefault(undefined);
const namedResource: boolean = wasm.namedResourceDefault({value: undefined});
const nullResource: boolean = native.namedResourceDefault({value: null});
const resourceConstructor: root.DefaultBase = root.DefaultBase.resource(undefined);
const resourceMember: boolean = new root.DefaultChild().checkResource(undefined);
const resourceFuture: Promise<number> = native.resourceDefaultLater(() => {}, {value: undefined});
const resourceStream: AsyncIterableIterator<number, undefined, undefined> =
  root.resourceDefaultSequence({value: undefined});
const resourceSignal: number = wasm.resourceDefaultSignal(new AbortController().signal);
void [constResource, namedResource, nullResource, resourceConstructor,
  resourceMember, resourceFuture, resourceStream, resourceSignal];
// @ts-expect-error Non-null resource defaults retain their nullability.
root.resourceDefault(null);
// @ts-expect-error Default resources retain backend ownership.
native.resourceDefault(constResource);

const originPoint: wasm.NamedPoint = wasm.originPointDefault(undefined);
const staticOriginPoint: native.NamedPoint = native.staticObjectDefault();
const originContainers: boolean = root.namedContainerDefaults(undefined, new Map());
const originValueField: boolean = native.namedValueFieldDefault({point: undefined});
const originResource: wasm.NamedResource = wasm.originResourceDefault();
const staticOriginResource: wasm.NamedResource = wasm.NamedResource.origin;
const originUse: number = wasm.namedResourceUse(() => {}, originResource);
void [originPoint, staticOriginPoint, originContainers, originValueField,
  staticOriginResource, originUse];
// @ts-expect-error Public constants do not expose their private Dart constructor.
new wasm.NamedPoint();
// @ts-expect-error Constant object defaults retain reference ownership.
native.namedValueFieldDefault({point: originPoint});

const hiddenPoint: wasm.HiddenPoint = wasm.hiddenDefault();
const hiddenNamed: wasm.HiddenPoint | null = wasm.hiddenNamedDefault({point: undefined});
const hiddenOwner: wasm.HiddenDefault = new wasm.HiddenDefault(hiddenPoint);
const hiddenConcrete: native.HiddenIntDefault = new native.HiddenIntDefault(3, {});
const hiddenFuture: Promise<wasm.HiddenPoint> = wasm.hiddenDefaultLater(undefined);
const hiddenVoid: void = wasm.hiddenDefaultVoid({point: hiddenPoint});
const hiddenStream: AsyncIterableIterator<wasm.HiddenPoint, undefined, undefined> = wasm.HiddenDefault.sequence();
void [hiddenNamed, hiddenConcrete, hiddenFuture, hiddenVoid, hiddenStream];
// @ts-expect-error Omission does not permit null for a non-nullable parameter.
wasm.hiddenDefault(null);
// @ts-expect-error Supplied defaultable references keep their backend ownership.
native.hiddenDefault(hiddenPoint);
// @ts-expect-error The private Dart constructor is not exposed.
new wasm.HiddenPoint();
// @ts-expect-error Omitted defaults do not weaken other constructor parameters.
new native.HiddenIntDefault('3');

const hiddenValue: wasm.HiddenNamedValue = wasm.hiddenNamedValue({origin: undefined});
const hiddenValuePoint: wasm.HiddenPoint | null = hiddenValue.origin;
const hiddenPositionalValue: native.HiddenPositionalValue = native.hiddenPositionalValue({offset: undefined});
const hiddenResource = new wasm.Resource(3);
const hiddenPayload = {tag: 'opaque'};
const hiddenFactory: wasm.HiddenFactoryValue<typeof hiddenPayload> =
  wasm.hiddenFactoryValue({payload: hiddenPayload, resource: hiddenResource});
const hiddenInteger: wasm.HiddenIntValue = wasm.hiddenIntValue({payload: 3, resource: hiddenResource});
void [hiddenValuePoint, hiddenPositionalValue, hiddenFactory, hiddenInteger];
// @ts-expect-error The renamed JS field uses its public name, not the Dart parameter name.
wasm.hiddenNamedValue({source: hiddenPoint});
// @ts-expect-error A non-nullable value constructor default still rejects null.
wasm.hiddenPositionalValue({point: null});
// @ts-expect-error Concrete factory aliases retain their scalar input type.
wasm.hiddenIntValue({payload: '3', resource: hiddenResource});

const resourceContainers: boolean = wasm.resourceContainerDefaults(undefined,
  new Map([['both', [constResource]]]), {both: [constResource]},
  {$1: [constResource], resource: constResource});
const nullableResourceContainer: boolean = native.namedResourceContainerDefault({values: null});
const resourceContainerFuture: Promise<number> = wasm.resourceContainerLater(() => {}, {values: undefined});
const resourceContainerStream: AsyncIterableIterator<number, undefined, undefined> =
  native.resourceContainerSequence({values: undefined});
void [resourceContainers, nullableResourceContainer, resourceContainerFuture, resourceContainerStream];
// @ts-expect-error Non-null resource container defaults still reject null.
wasm.resourceContainerDefaults(null);
// @ts-expect-error Resources inside defaultable containers retain backend ownership.
native.resourceContainerLater(() => {}, {values: [constResource]});
