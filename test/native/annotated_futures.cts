import addon = require('./addon');

const value: Promise<number> = addon.asyncValue(7);
const echoed: Promise<number> = addon.echoFuture(Promise.resolve(9));
const offset: Promise<number> = addon.futureWithOffset(Promise.resolve(9), 2);
const ignored: Promise<void> = addon.completeVoid(Promise.resolve());
const nullableValue: Promise<number | null> = addon.nullableValue(Promise.resolve(null));
const nullableFuture: Promise<number> | null = addon.nullableFuture();
const absentFuture: Promise<number> | null = addon.nullableFuture(null);
const never: Promise<never> = addon.failNever();
const counter = new addon.AsyncCounter(3);
const increment: Promise<number> = counter.increment(2);
const doubled: Promise<number> = counter.doubled;
const futures: Promise<number | null>[] = addon.futureList([Promise.resolve(1), Promise.resolve(null)]);
const applied: Promise<number> = addon.applyAsync(3, async value => value + 1);
const multiplied: Promise<number> = addon.multiplyAsync(2)(3);
const forwarded: Promise<number> = addon.passFuture(async promise => (await promise) + 1);
const notified: Promise<void> = addon.notifyAsync(async () => {});
const thenable: Promise<number> = addon.thenable(7);
const flattened: Promise<number> = addon.nestedFuture();
const nestedInput: Promise<number> = addon.readNested(Promise.resolve(8));
const deepInput: Promise<number> = addon.readDeepNested(Promise.resolve(9));
const echoedNested: Promise<number> = addon.echoNested(Promise.resolve(10));
const missingNested: Promise<boolean> = addon.nestedMissing(Promise.resolve(null));
const presentNested: Promise<boolean> = addon.nestedMissing(Promise.resolve(11));
const nullNested: Promise<number | null> = addon.nestedNullableValue(Promise.resolve(null));
const voidNested: Promise<void> = addon.nestedVoid(Promise.resolve());
const callbackNested: Promise<number> = addon.nestedCallback(async () => 13);
addon.thenable(7).then(value => { const number: number = value; return number + 1; });
async function values() {
  const assimilated: number = await addon.thenable(7);
  const nested: number = await addon.nestedFuture();
}

// @ts-expect-error Future inputs require Promise values.
addon.echoFuture(7);
// @ts-expect-error A Promise must fulfill with the declared type.
addon.echoFuture(Promise.resolve('wrong'));
// @ts-expect-error Arguments after a Future retain their declared types.
addon.futureWithOffset(Promise.resolve(9), '2');
// @ts-expect-error Every list element must be a Promise.
addon.futureList([Promise.resolve(1), 1]);
// @ts-expect-error Nullable Future values exclude undefined.
addon.nullableFuture(undefined);
// @ts-expect-error Nullable elements exclude undefined.
addon.nullableValue(Promise.resolve(undefined));
// @ts-expect-error A callback returning Future requires a Promise result.
addon.applyAsync(1, value => value + 1);
// @ts-expect-error Returned async functions retain argument types.
addon.multiplyAsync(2)('3');
// @ts-expect-error Standard Promise assimilation produces number, not Thenable.
const unassimilated: Promise<addon.Thenable> = addon.thenable(7);
// @ts-expect-error Nested Futures still require a Promise.
addon.readNested(8);
// @ts-expect-error The flattened value retains its declared type.
addon.readNested(Promise.resolve('wrong'));
// @ts-expect-error A non-nullable nested Future cannot contain null.
addon.readNested(Promise.resolve(null));
// @ts-expect-error A nullable inner Future does not accept undefined.
addon.nestedMissing(Promise.resolve(undefined));
// @ts-expect-error Callback results still require a Promise.
addon.nestedCallback(() => 13);
// @ts-expect-error Then callbacks also receive the assimilated number.
addon.thenable(7).then((value: addon.Thenable) => value.value);
