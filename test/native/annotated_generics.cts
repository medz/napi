import addon = require('./addon');

const inferred: number = addon.identity(42);
const explicit: string = addon.identity<string>('hello');
const nullable: null = addon.identity(null);
const maybe: number | null = addon.nullable<number>(null);
const pair: [number, string] = addon.pair(42, 'hello');
const box = new addon.Box<number>(42);
const variable: addon.Box<any> = addon.box;
const defaultBox: addon.Box = addon.box;
addon.box = box;
const inferredBox = new addon.Box('hello');
const value: number = box.value;
const text: string = inferredBox.value;
const previous: number = box.replace(7);
const method: string = box.echo<string>('hello');
box.value = 9;
const same: addon.Box<number> = addon.echoBox(box);
const concrete: addon.Box<number> = addon.intBox();
const concreteValue: number = addon.readBox(concrete);
const concreteParent: addon.Box<number> = addon.parentBox();
const concreteChild: addon.LabeledBox<number> = addon.labeledBox();
const concreteEcho: addon.LabeledBox<number> = addon.intBoxIdentity()(concreteChild);
const nullableConcrete: addon.Box<number> | null = addon.nullableIntBox(null);
const nullableText: string | null = addon.textBox().value;
const anyValue: unknown = addon.anyBox().value;
addon.anyBox().value = { value: 'opaque' };
const concreteBigInt: bigint = addon.bigIntBox().value;
const concreteObject: object = addon.objectBox({}).value;
addon.callIntBox(value => value);
const adjusted = addon.adjustedBox();
const adjustedPrevious: number = adjusted.replace(5, 3);
const adjustedDefault: number = adjusted.replace(5);
const scaled: addon.Box<number> = addon.scaledBox();
const lists: addon.Box<number[]> = addon.listBox();
const listElement: number = lists.value[0];
lists.value = [3, 4];
const previousList: number[] = lists.replace([5]);
const nestedLists: number[][] = lists.items;
const labeledList: addon.LabeledBox<number[]> = addon.labeledListBox();
const mapValues: { [key: string]: (number | null)[] } = addon.mapBox().value;
const setValues: Set<number> = addon.setBox().value;
const recordValue: { $1: number; label: string } = addon.recordBox().value;
const pairValue: [number, number] = addon.pairBox().value;
const nullableListValue: number[] | null = addon.nullableListBox().value;
const referenceValues: object[] = addon.referenceListBox([{}]).value;
const dateValue: Date = addon.dateBox().value;
const bytesValue: Uint8Array = addon.bytesBox().value;
const dataValue: DataView = addon.dataBox().value;
const vectorValue: Float32Array = addon.vectorBox().value;
const stageValue: addon.Stage = addon.stageBox().value;
const futureValue: Promise<number[]> = addon.futureBox().value;
const doneValue: Promise<void> = addon.doneBox().value;
addon.futureBox().value = Promise.resolve([3]);
const previousFuture: Promise<number[]> = addon.futureBox().replace(Promise.resolve([4]));
addon.doneBox().value = Promise.resolve();
const callbacks: addon.Box<(value: number) => number> = addon.callbackBox();
const callbackResult: number = callbacks.value(1);
const constructedCallbacks = new addon.NamedCallbackBox(({value}) => value.toFixed());
const constructedCallbackResult: string = constructedCallbacks.call(1);
callbacks.value = value => value + 1;
const previousCallback: (value: number) => number = callbacks.replace(value => value + 2);
const namedCallbackResult: number = addon.namedCallbackBox().value({value: 1});
addon.namedCallbackBox().value = ({value}) => value + 1;
const optionalCallback = addon.optionalCallbackBox().value;
optionalCallback(1);
optionalCallback(1, null);
optionalCallback(1, 2);
const asyncCallbackResult: Promise<number[]> = addon.asyncCallbackBox().value([1, 2]);
addon.asyncCallbackBox().value = async values => [...values, 3];
const nullableCallbackResult: number | undefined = addon.nullableCallbackBox().value?.(1);
addon.nullableCallbackBox().value = null;
const callbackListResult: number = addon.callbackListBox().value[0](1);
const eventResult: void = addon.eventBox().value();
const bound: addon.Box<addon.Counter> = addon.boundBox();
const boxedCounter: addon.Counter = bound.value;
bound.value = new addon.SpecialCounter(1);
const specialValue: addon.SpecialCounter = addon.specialBoundBox().value;
const boundListValue: (addon.Counter | null)[] = addon.boundListBox([boxedCounter, null]).value;
const nestedBoundValue: addon.Box<number> = addon.nestedBoundBox().value;
const boundCallbackValue: addon.Counter = addon.boundCallbackBox().value(boxedCounter);
const boundFutureValue: Promise<addon.Counter> = addon.boundFutureBox().value;
const taggedFutureValue: Promise<addon.Tag<number>> = addon.taggedFutureBox().value;
// @ts-expect-error A plain object is not a bound Counter instance.
bound.value = {value: 1};
// @ts-expect-error A base instance is not a SpecialCounter.
addon.specialBoundBox().value = boxedCounter;
// @ts-expect-error Callback results retain their scalar type.
callbacks.value = () => 'wrong';
// @ts-expect-error The callback requires its named argument.
addon.namedCallbackBox().value({});
// @ts-expect-error Omission is distinct from explicit undefined.
optionalCallback(1, undefined);
// @ts-expect-error Promise elements retain the concrete nested scalar type.
addon.futureBox().value = Promise.resolve(['wrong']);
// @ts-expect-error A timestamp's numeric representation is not a Date input.
addon.dateBox().value = 2000;
// @ts-expect-error Nested concrete elements retain their scalar type.
lists.value = ['wrong'];
// @ts-expect-error The container argument is also checked by TypeScript.
addon.consumeListBox(new addon.Box(['wrong']));
// @ts-expect-error Nullable list elements still exclude undefined.
addon.mapBox().value = { values: [undefined] };
// @ts-expect-error All named record fields are required.
addon.recordBox().value = { $1: 2 };
// @ts-expect-error Concrete arguments must retain the class's member type.
concrete.value = 'wrong';
// @ts-expect-error A different generic instance is not a Box<number>.
addon.consumeIntBox(new addon.Box('wrong'));
// @ts-expect-error Nullable elements do not make the Box itself nullable.
const missingBox: null = addon.textBox();
const items: number[] = box.items;
const named: { [key: string]: number } = box.named;
const list: number[] = addon.copyList([1, 2]);
const map: { [key: string]: string } = addon.copyMap({ item: 'hello' });
const numeric: number = addon.numeric(1.5);
const numericNull: null = addon.nullableNumeric(null);
const constrained: number | null = addon.nullableNumeric<number | null>(null);
const nonNull: undefined = addon.nonNull(undefined);
const object = addon.reference({ value: 7 });
const objectValue: number = object.value;
const callback = addon.reference((value: number) => value + 1);
const result: number = callback(3);
const applied: number = addon.apply(3, value => value + 1);
const child = new addon.NumericChild();
const inherited: number = child.echo<number>(1.5);
const genericChild = new addon.GenericNumericChild<number>();
const genericInherited: number = genericChild.echo(1.5);

const counter = new addon.SpecialCounter(7);
const sameCounter: addon.SpecialCounter = addon.boundIdentity(counter);
const nullableCounter: null = addon.nullableBound(null);
const counterBox = new addon.CounterBox(counter);
const boundValue: addon.SpecialCounter = counterBox.value;
const boundEcho: addon.SpecialCounter = counterBox.echo(counter);
const boundResult: boolean = addon.boundCallback(counter, value => value);
const returnedCounter: addon.SpecialCounter = addon.boundFunction()(counter);
const handlerResult: boolean = addon.handleCounter({ run: value => value }, counter);
const nullableHandlerResult: boolean = addon.handleNullableCounter({ run: value => value }, null);
const handlerCounter: addon.SpecialCounter = addon.counterHandler().run(counter);
const asyncBound: Promise<addon.SpecialCounter> = addon.asyncBoundCallback(counter, async value => value);

// @ts-expect-error Bound class constraints exclude scalar type arguments.
addon.boundIdentity<number>(7);
// @ts-expect-error A class-constrained field cannot hold a scalar.
counterBox.value = 7;
// @ts-expect-error The callback must preserve the actual subclass type.
addon.boundCallback(counter, () => new addon.Counter(7));
// @ts-expect-error Generic constraints propagate through structural type arguments.
addon.counterHandler().run(7);

// @ts-expect-error Explicit function type arguments preserve the relation.
addon.identity<string>(42);
// @ts-expect-error Nullable generic arguments retain the supplied type.
addon.nullable<number>('42');
// @ts-expect-error Each type parameter keeps its own argument relation.
addon.pair<number, string>(42, 7);
// @ts-expect-error Constructor type arguments constrain values.
new addon.Box<number>('42');
// @ts-expect-error Generic fields retain their class type parameter.
box.value = '9';
// @ts-expect-error Generic methods retain their class type parameter.
box.replace('9');
// @ts-expect-error Methods can also declare their own type parameter.
box.echo<string>(7);
// @ts-expect-error Numeric bounds exclude String.
addon.numeric('7');
// @ts-expect-error Nullable numeric bounds exclude undefined.
addon.nullableNumeric(undefined);
// @ts-expect-error Object bounds exclude null.
addon.nonNull(null);
// @ts-expect-error Reference bounds exclude scalar inputs.
addon.reference(7);
// @ts-expect-error Callback input and result are related to the first argument.
addon.apply<number>(3, () => '4');
// @ts-expect-error Omitted class type arguments default to unknown.
defaultBox.value.missing;
// @ts-expect-error Inherited method bounds substitute Base<T> with num.
child.echo<string>('wrong');
// @ts-expect-error Method and owner parameters named U retain separate bounds.
genericChild.echo<string>('wrong');
