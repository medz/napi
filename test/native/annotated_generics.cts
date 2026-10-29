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
const nestedFutures: addon.Box<Promise<number>> = addon.nestedFutureBox();
const nestedSubclass: addon.FutureBox<Promise<number>> = addon.nestedFutureBox();
nestedSubclass.value = Promise.resolve(8);
const subclassPrevious: Promise<number> = nestedSubclass.replace(Promise.resolve(9));
const constructedFuture = new addon.FutureBox(Promise.resolve([1]));
const constructedFutureValue: Promise<number[]> = constructedFuture.value;
const nestedValue: Promise<number> = nestedFutures.value;
nestedFutures.value = Promise.resolve(8);
const previousNested: Promise<number> = nestedFutures.replace(Promise.resolve(9));
const nestedAmounts: addon.Box<Promise<addon.Amount>> = addon.nestedAmountBox();
const nestedAmount: Promise<addon.Amount> = nestedAmounts.value;
nestedAmounts.value = Promise.resolve({value: '4'});
const nullableNested: addon.Box<Promise<number | null>> = addon.nullableNestedBox();
nullableNested.value = Promise.resolve(null);
nullableNested.value = Promise.resolve(10);
const missingNested: Promise<boolean> = addon.nestedBoxMissing(nullableNested);
// @ts-expect-error Nested Future values retain their scalar type.
nestedFutures.value = Promise.resolve('wrong');
// @ts-expect-error Nested Future input uses the Amount constructor shape.
nestedAmounts.value = Promise.resolve({value: 4});
// @ts-expect-error Nullable Future values do not accept undefined.
nullableNested.value = Promise.resolve(undefined);
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
const hiddenThenFuture: Promise<addon.Counter> = addon.hiddenThenFutureBox().value;
type PassResolver = (resolve: (value: number) => void) => void;
const resolveOne: PassResolver = done => done(1);
const thenables = addon.thenableBox();
const thenableValue: Promise<number> = thenables.value;
thenables.value = Promise.reject(new Error('rejected'));
// @ts-expect-error Promise resolution adopts the Thenable.
thenables.value = new Promise<addon.Thenable>(resolve => resolve(new addon.Thenable(1)));
// @ts-expect-error A fulfilled number cannot become a Thenable.
thenables.value = Promise.resolve(1);
// @ts-expect-error The adopted read value cannot be written back.
thenables.value = thenables.value;
const tickets = addon.ticketBox();
const ticketValues: Promise<addon.Ticket | string>[] = tickets.value;
tickets.value = [Promise.resolve(new addon.Ticket(1)), Promise.resolve(new addon.NamedTicket(2))];
// @ts-expect-error A thenable subclass can replace the Ticket.
const plainTickets: Promise<addon.Ticket>[] = tickets.value;
// @ts-expect-error Promise resolution adopts the SettledTicket.
tickets.value = [Promise.resolve(new addon.SettledTicket(3))];
// @ts-expect-error An explicitly typed Promise still excludes SettledTicket.
tickets.value = [new Promise<addon.SettledTicket>(resolve => resolve(new addon.SettledTicket(3)))];
// @ts-expect-error Adopted values cannot be written back.
tickets.value = tickets.value;
const ticketResult: Promise<addon.Ticket | string> = addon.ticket(true);
// @ts-expect-error A Ticket result can be adopted by SettledTicket.
const plainTicket: Promise<addon.Ticket> = addon.ticket(false);
const resolvers = addon.resolverBox(false);
const resolverValue: Promise<{ [key: string]: (resolve: (value: number) => void) => void } | number> = resolvers.value;
resolvers.value = Promise.resolve({ other() {} });
// @ts-expect-error A callable then entry is adopted.
resolvers.value = new Promise<{ then: PassResolver }>(resolve => resolve({ then: resolveOne }));
addon.passId(Promise.resolve(new addon.Pass(1)));
// @ts-expect-error A sibling with an unknown then makes the result unknown.
const knownPass: Promise<addon.Pass> = addon.pass(0);
// @ts-expect-error A callable then is still excluded beside an unknown sibling.
addon.passId(new Promise<addon.SettledPass>(resolve => resolve(new addon.SettledPass(2))));
// @ts-expect-error A then that may be callable is excluded from inputs.
addon.passId(new Promise<addon.OpaquePass<PassResolver>>(resolve => resolve(new addon.OpaquePass(3, resolveOne))));
const json = addon.jsonBox();
json.value = Promise.resolve({ then: null, other: 1 });
// @ts-expect-error An unknown then entry may be adopted.
json.value = new Promise<{ then: PassResolver }>(resolve => resolve({ then: resolveOne }));
// Subclasses of other instantiations do not change Label<boolean>.
const flag: Promise<boolean> = addon.readFlagLabel(addon.flagLabel());
// Counter and Stage are not lists, so their subclasses do not change Label<number[]>.
const listLength: Promise<number> = addon.readListLabel(addon.listLabel());
const labelText: Promise<addon.Label<string> | addon.Label<string[]>> = addon.textLabel(true);
// @ts-expect-error NestedLabel can adopt a Label<string[]>.
const plainText: Promise<addon.Label<string>> = addon.textLabel(false);
const numberText: Promise<addon.Label<number> | string> = addon.numberLabel(true);
// @ts-expect-error NumberLabel is a Label<num> and can adopt a string.
const plainNumber: Promise<addon.Label<number>> = addon.numberLabel(false);
const optionalValue: Promise<addon.Label<number | null> | string | number | null> = addon.optionalLabel(true);
// @ts-expect-error OptionalLabel<int?> can adopt null.
const presentValue: Promise<addon.Label<number | null> | string | number> = addon.optionalLabel(false);
type SlotValue = Awaited<ReturnType<typeof addon.slot>>;
declare const adoptedSlot: Extract<SlotValue, (...args: never[]) => unknown>;
adoptedSlot(1);
// @ts-expect-error NumberSlot<T extends num> resolves a callback that keeps its bound.
adoptedSlot('one');
const taggedFutureValue: Promise<addon.Tag<number>> = addon.taggedFutureBox().value;
const numericTagName: string = addon.NumericTag.name;
declare const unknownTag: unknown;
if (unknownTag instanceof addon.NumericTag) {
  const numericTag: number = unknownTag.then;
}
// @ts-expect-error Generic classes without an annotated constructor remain unconstructable.
new addon.NumericTag(1);
const amounts: addon.Box<addon.Amount> = addon.amountBox();
amounts.value = {value: '42'};
const amount: addon.Amount = amounts.value;
const previousAmount: addon.Amount = amounts.replace({value: '43'});
const parcel: addon.Box<addon.Parcel<addon.Amount>> = addon.parcelBox();
parcel.value = {item: {value: '8'}};
const parcelAmount: addon.Amount = parcel.value.item;
const labeledAmount: addon.LabeledBox<addon.Amount> = addon.labeledAmountBox();
const amountParent: addon.Box<addon.Amount> = labeledAmount;
const rawAmount = new addon.Box(amount);
rawAmount.value = amount;
const rawAmountValue: addon.Amount = rawAmount.value;
const namedRawAmount = addon.Box.named(amount);
const factoryRawAmount = addon.Box.from(amount);
const wrappedRawAmount = addon.wrapBox(amount);
const relatedRawAmount = new addon.Related<addon.Amount, addon.Amount>(amount);
relatedRawAmount.value = amount;
const relatedNumber: addon.Related<number, number> = new addon.Related(1);
namedRawAmount.value = amount;
factoryRawAmount.value = amount;
wrappedRawAmount.value = amount;
const echoedAmount = addon.echoBox(rawAmount);
echoedAmount.value = amount;
const reboxedAmount: addon.Box<addon.Amount> = addon.rebox(amounts, {value: '42'});
reboxedAmount.value = {value: '43'};
const reboxedAmountValue: addon.Amount = reboxedAmount.value;
const reboxedRaw = addon.rebox(rawAmount, rawAmount.value);
reboxedRaw.value = amount;
const boxedAgain = new addon.Box(rawAmount.value);
boxedAgain.value = amount;
const pickedAmount = addon.pickBox([amounts]);
const callbackAmount = addon.pickCallbackBox(() => amounts);
const pickedRaw = addon.pickBox([rawAmount]);
pickedRaw.value = amount;
class JsAmountBox extends addon.Box<addon.Amount> {}
const jsAmountBox = new JsAmountBox(amount);
jsAmountBox.value = amount;
class JsGenericBox<T> extends addon.Box<T> {}
const jsGenericBox = new JsGenericBox(amount);
jsGenericBox.value = amount;
const fixedAmount: addon.Box<addon.Amount> = new addon.AmountBox({value: '1'});
fixedAmount.value = {value: '2'};
addon.amountListBox().value = [{value: '3'}, null];
const amountListValue: (addon.Amount | null)[] = addon.amountListBox().value;
addon.futureAmountBox().value = Promise.resolve({value: '4'});
const amountFutureValue: Promise<addon.Amount> = addon.futureAmountBox().value;
const asyncAmounts: AsyncIterable<{value: string}> = {async *[Symbol.asyncIterator]() { yield {value: '5'}; }};
addon.streamAmountBox().value = asyncAmounts;
const amountStep: Promise<IteratorResult<addon.Amount>> = addon.streamAmountBox().value.next();
addon.amountCallbackBox().value = value => ({value: String(value.value + 1)});
const callbackAmountValue: addon.Amount = addon.amountCallbackBox().value({value: '6'});
const amountPair: addon.Box<[addon.Amount, addon.Amount]> = addon.amountPairBox();
amountPair.value = [{value: '3'}, {value: '4'}];
const rawAmountPair = new addon.PairBox(amount, amount);
rawAmountPair.value = [amount, amount];
const rawAmountArray = new addon.Box([amount]);
rawAmountArray.value = [amount];
addon.calculatedAmountBox().value = value => ({value: String(value * 2)});
const calculatedAmountValue: addon.Amount = addon.calculatedAmountBox().value(3);
const scalarWide: addon.Box<unknown> = box;
const nativeWide: addon.Box<unknown> = amounts;
const rawWide: addon.Box<unknown> = rawAmount;
declare const literalBox: addon.Box<1>;
const numberBox: addon.Box<number> = literalBox;
// @ts-expect-error Native boxes require the data class's constructor input.
amounts.value = amount;
// @ts-expect-error A generic data class retains nested constructor input.
parcel.value = {item: amount};
// @ts-expect-error Raw JS boxes keep opaque values without data-class conversion.
rawAmount.value = {value: '1'};
// @ts-expect-error Named constructors preserve opaque inputs.
namedRawAmount.value = {value: '1'};
// @ts-expect-error Dart factories called through JS preserve opaque inputs.
factoryRawAmount.value = {value: '1'};
// @ts-expect-error Generic wrappers without an instance type also remain opaque.
wrappedRawAmount.value = {value: '1'};
// @ts-expect-error Dependent generic bounds keep opaque constructor inputs.
relatedRawAmount.value = {value: '1'};
// @ts-expect-error Raw and native boxes have different write contracts.
const wrongAmountBox: addon.Box<addon.Amount> = rawAmount;
// @ts-expect-error Unions cannot hide opaque storage behind another branch.
const wrongAmountUnion: addon.Box<addon.Amount | number> = rawAmount;
// @ts-expect-error Generic identity helpers retain the input contract.
echoedAmount.value = {value: '1'};
// @ts-expect-error JS subclasses keep their opaque constructor behavior.
jsAmountBox.value = {value: '1'};
// @ts-expect-error Generic JS subclasses keep their opaque constructor behavior.
jsGenericBox.value = {value: '1'};
// @ts-expect-error Collection elements retain constructor input types.
addon.amountListBox().value = [amount];
// @ts-expect-error Promise values retain constructor input types.
addon.futureAmountBox().value = Promise.resolve(amount);
// @ts-expect-error Stored callback inputs and outputs use opposite directions.
addon.amountCallbackBox().value = value => value;
// @ts-expect-error A converted tuple still retains opaque element inputs.
const wrongAmountPair: addon.Box<[addon.Amount, addon.Amount]> = rawAmountPair;
// @ts-expect-error Widening one tuple position cannot erase another position's conversion.
const wrongWideAmountPair: addon.Box<[addon.Amount, unknown]> = rawAmountPair;
// @ts-expect-error Reified Amount inputs use the Dart constructor's shape.
reboxedAmount.value = amount;
// @ts-expect-error Nested class inputs can preserve native conversion.
pickedAmount.value = amount;
// @ts-expect-error A callback result can preserve native conversion too.
callbackAmount.value = amount;
// @ts-expect-error An opaque array does not acquire data-class conversion.
const wrongAmountArray: addon.Box<addon.Amount[]> = rawAmountArray;
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
