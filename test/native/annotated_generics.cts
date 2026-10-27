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
