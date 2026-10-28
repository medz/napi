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
