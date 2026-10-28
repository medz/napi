import addon = require('./addon');

const double = addon.doubleBox();
const number: number = addon.writeBox(double, 2);
const numeric: number = addon.numeric(double, 3);
const list: number[] = addon.writeBox(addon.listBox(), [1, 2]);
const amountBox = addon.amountBox();
const amount: addon.Amount = addon.writeBox(amountBox, {value: '42'});
const reboxed: addon.Box<addon.Amount> = addon.rebox(amountBox, {value: '43'});
reboxed.value = {value: '44'};
const named: addon.Amount = addon.namedBox({box: amountBox, value: {value: '45'}});
const pair: addon.Amount = addon.writePair(addon.pair(), 1, {value: '46'});
const method: addon.Amount = addon.service().update(amountBox, {value: '47'});
const optional: addon.Amount = addon.optionalBox({value: '48'}, amountBox);
const fallback: {value: number} = addon.optionalBox({value: 49});
const nullable: {value: number} = addon.optionalBox({value: 50}, null);
const optionalBox: addon.Box<addon.Amount> = addon.optionalRebox({value: '51'}, amountBox);
const rawBox = addon.optionalRebox(amount);
rawBox.value = amount;
const transformed: addon.Amount = addon.transform(amountBox, value => ({value: String(value.value)}));
const asynchronous: Promise<addon.Amount> = addon.asynchronous(amountBox, Promise.resolve({value: '52'}));
const futureValue: Promise<number> = addon.asynchronous(addon.futureBox(), Promise.resolve(13));
const futureAmount: Promise<addon.Amount> = addon.asynchronous(addon.futureAmountBox(), Promise.resolve({value: '14'}));
const nullableFuture: Promise<number | null> = addon.asynchronous(addon.nullableFutureBox(), Promise.resolve(null));
const nullableFutureValue: Promise<number | null> = addon.asynchronous(addon.nullableFutureBox(), Promise.resolve(15));
const boundedFuture: Promise<number> = addon.asynchronousBound(addon.futureBox(), Promise.resolve(14));
const boundedAmount: Promise<addon.Amount> = addon.asynchronousBound(addon.futureAmountBox(), Promise.resolve({value: '15'}));
const boundedNullable: Promise<number | null> = addon.asynchronousBound(addon.nullableFutureBox(), Promise.resolve(16));
// @ts-expect-error Future-valued type arguments keep their scalar conversion.
addon.asynchronous(addon.futureBox(), Promise.resolve('wrong'));
// @ts-expect-error Future-valued Amount inputs use the constructor shape.
addon.asynchronous(addon.futureAmountBox(), Promise.resolve({value: 14}));
const collection: addon.Amount[] = addon.collection(amountBox, [{value: '53'}]);
const copiedList: number[] = addon.writeList(addon.listBox(), [1, 2]);
const copiedAmount: addon.Amount = addon.writeAmount(amountBox, {value: '19'});
const copiedCallback: addon.Amount = addon.transformAmount(amountBox, value => ({value: String(value.value)}));
const namedList: number[] = addon.namedList({box: addon.listBox(), value: [3]});
const listDefault: number[] = addon.listDefault(addon.listBox(), [4]);
const copiedMethod: number[] = addon.service().copy(addon.listBox(), [5]);
const appended: number[] = addon.append(addon.listBox(), 2);
// @ts-expect-error The list bound relates its element type to the value.
addon.append(addon.listBox(), 'wrong');
const copiedBytes: Uint8Array = addon.writeList(addon.bytesBox(), new Uint8Array([6]));
const defaultBytes: Uint8Array = addon.listDefault(addon.bytesBox(), new Uint8Array([7]));
const copiedWide: BigInt64Array = addon.writeList(addon.int64Box(), new BigInt64Array([8n]));
const nullableList: number[] | null = addon.writeNullableList(addon.nullableListBox(), null);
const nonNullList: number[] = addon.writeNullableList(addon.listBox(), [9]);
// @ts-expect-error A copied list does not retain extra input properties.
addon.writeList(addon.listBox(), Object.assign([1], {label: 'input'})).label;
// @ts-expect-error The bound excludes scalar instances.
addon.writeList(double, 1);
// @ts-expect-error The instance determines the element type.
addon.writeList(addon.listBox(), ['1']);
// @ts-expect-error Uint8List keeps its typed-array input conversion.
addon.writeList(addon.bytesBox(), [1]);
// @ts-expect-error A dependent default follows the actual Uint8List type.
addon.listDefault(addon.bytesBox(), [1]);
// @ts-expect-error Data-class bounds retain their constructor input shape.
addon.writeAmount(amountBox, {value: 19});
// @ts-expect-error Callback results use the selected data-class input shape.
addon.transformAmount(amountBox, value => value);
// @ts-expect-error A nullable bound does not make a non-null instance nullable.
addon.writeNullableList(addon.listBox(), null);
const opaque = new addon.Box(amount);
const opaqueValue: addon.Amount = addon.writeBox(opaque, amount);
const opaqueResult = addon.rebox(opaque, amount);
opaqueResult.value = amount;
const dependent: number = addon.dependent(double, double, 2);
const defaultValue: addon.Amount = addon.defaultValue(amountBox, {value: '54'});
const namedOptional: addon.Amount = addon.namedOptional({value: '55'}, {box: amountBox});
const namedFallback: addon.Amount = addon.namedOptional(amount, {box: null});
const readout: (addon.Readout | null)[] = addon.read(addon.readoutBox());
const nullReadout: (addon.Readout | null)[] = addon.fromInput(addon.readoutBox(), [null]);
declare const maybeNumber: addon.Box<number> | null;
declare const maybeAmount: addon.Box<addon.Amount> | null;
const maybe: number = addon.optionalBox(2, maybeNumber);
const maybeReboxed: addon.Box<number> = addon.optionalRebox(2, maybeNumber);
const maybeNamed: number = addon.namedOptional(2, {box: maybeNumber});
addon.sameType(maybeNumber, maybeNumber);

// @ts-expect-error The value cannot change the type selected by the box.
addon.writeBox(double, '2');
// @ts-expect-error Data-class inputs use the constructor shape.
addon.writeBox(amountBox, {value: 42});
// @ts-expect-error Return context cannot replace the box's selected type.
const wrongContext: string = addon.writeBox(double, '2');
// @ts-expect-error An opaque box does not acquire data-class conversion.
addon.writeBox(opaque, {value: '42'});
// @ts-expect-error An absent anchor does not convert a data class.
const wrongFallback: addon.Amount = addon.optionalBox({value: '42'});
// @ts-expect-error Undefined is not an omitted nullable box.
addon.optionalBox(amount, undefined);
// @ts-expect-error The present-box overload requires the input shape.
addon.optionalBox(amount, amountBox);
// @ts-expect-error An unanchored result retains its opaque input shape.
const wrongBox: addon.Box<addon.Amount> = rawBox;
// @ts-expect-error A callback returns constructor input, not output fields.
addon.transform(amountBox, value => value);
// @ts-expect-error Collection elements use the selected input conversion.
addon.collection(amountBox, [{value: 42}]);
// @ts-expect-error A dependent default uses the bound's constructor input.
addon.defaultValue(amountBox, amount);
// @ts-expect-error A data class without an input constructor cannot be supplied.
addon.fromInput(addon.readoutBox(), [{value: 42}]);
// @ts-expect-error The input must also work when the Amount box is absent.
addon.optionalBox({value: '42'}, maybeAmount);
// @ts-expect-error The output shape fails when the Amount box is present.
addon.optionalBox(amount, maybeAmount);
