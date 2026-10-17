import {ReadBase, ReadView, WriteView, ExtraView, makeReadView, makeWriteView,
  echoReadView, echoWriteView, echoExtraView, compositeViews} from '@napi/class-fixture';

const read: ReadView = makeReadView(1);
const write: WriteView = makeWriteView(2);
const base: ReadBase = read;
const value: number = read.value;
write.value = 3;
const description: string = write.describe();
const named: number = read.shared(undefined);
const created: ReadView = new ReadView(3);
const views: {$1: ReadView; $2: WriteView; $3: ExtraView} = compositeViews(read);
void [base, value, description, named, created, echoReadView(read),
  echoWriteView(write), echoExtraView(views.$3)];
// @ts-expect-error runtime combinations do not invent declared inheritance
const unrelated: WriteView = read;
// @ts-expect-error a readonly view stays readonly
read.value = 4;
// @ts-expect-error this interface has no public constructor
new ExtraView();
