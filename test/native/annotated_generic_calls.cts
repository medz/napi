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
const collection: addon.Amount[] = addon.collection(amountBox, [{value: '53'}]);
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
