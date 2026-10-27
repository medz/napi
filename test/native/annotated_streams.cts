import addon = require('./addon');

const numbers: AsyncIterableIterator<number> = addon.numbers(3);
const collected: Promise<number[]> = addon.collect((async function* () { yield 1; })());
const nullable: AsyncIterableIterator<number> | null = addon.nullableStream();
const nullableValues: AsyncIterableIterator<number | null> = addon.nullableValues();
const voidValues: AsyncIterableIterator<void> = addon.voidValues();
const voidCount: Promise<number> = addon.countVoids((async function* () {})());
const item = new addon.StreamValue(7);
const repeated: AsyncIterableIterator<addon.StreamValue | null> = addon.repeatValue(item);
const state = new addon.StreamState();
const classValues: AsyncIterableIterator<number> = state.values();
const callback: Promise<number[]> = addon.collectFactory(() => addon.numbers(2));
const factory: (count: number) => AsyncIterableIterator<number> = addon.numberFactory();
const streams: AsyncIterableIterator<number>[] = addon.streamList([addon.numbers(1)]);
const nested: AsyncIterableIterator<Promise<number>> = addon.futureValues();
async function futureEvent() {
  const step = await nested.next();
  if (!step.done) {
    const value: Promise<number> = step.value;
  }
}

// @ts-expect-error Stream inputs require an AsyncIterable.
addon.collect([1, 2]);
// @ts-expect-error Stream elements retain their declared types.
addon.collect((async function* () { yield 'wrong'; })());
// @ts-expect-error Nullable Stream values exclude undefined.
addon.nullableStream(undefined);
// @ts-expect-error Callback results must be AsyncIterable values.
addon.collectFactory(() => [1, 2]);
// @ts-expect-error Stream output elements remain nullable.
const strict: AsyncIterableIterator<number> = addon.nullableValues();
