import * as api from '@napi/streams-fixture';
import * as direct from '@napi/streams-fixture/BACKEND';
import * as external from '@napi/streams-external';

const numbers: AsyncIterableIterator<number, undefined, undefined> = api.range();
const next: Promise<IteratorResult<number, undefined>> = numbers.next();
const completion: Promise<IteratorResult<number, undefined>> = numbers.return!();
const subpath: AsyncIterableIterator<number> = direct.range(2);
const selected: AsyncIterableIterator<number> = external.generated(2);
const empty: AsyncIterableIterator<void> = api.voidItems();
const strings: AsyncIterableIterator<string | null> = api.textItems(['a', null]);
const wide: AsyncIterableIterator<bigint> = api.wideItems([1n]);
const promise = Promise.resolve(17);
const promises: AsyncIterableIterator<Promise<number>> = api.echoItems(promise);
const thenable = {then(resolve: (value: number) => void) { resolve(7); }};
const raw: AsyncIterableIterator<typeof thenable> = api.echoItems(thenable);
const undefineds: AsyncIterableIterator<undefined> = api.echoItems(undefined);
const box = new api.StreamBox(2);
const getter: AsyncIterableIterator<number> = box.values;
const method: AsyncIterableIterator<number> = box.add();
const point: AsyncIterableIterator<api.StreamPoint> = api.pointItems({x: 1});
const feed = new api.OpaqueFeed<{value: number}>();
feed.emit({value: 3});
const typed: AsyncIterableIterator<{value: number}> = feed.values;
const owner = new api.StreamOwner(1);
const owned: AsyncIterableIterator<number> = owner.watch(1, {peer: owner, peers: [owner]});
const closed: Promise<void> = owner.close();
// @ts-expect-error Streams are returned synchronously, not Promise<Iterable>.
const future: Promise<AsyncIterable<number>> = api.range();
// @ts-expect-error Stream item T is not Awaited<T>.
const adopted: AsyncIterableIterator<number> = api.echoItems(promise);
// @ts-expect-error Stream<void> items are void.
const wrongVoid: AsyncIterableIterator<number> = api.voidItems();
// @ts-expect-error Input numeric validation remains strict.
api.range('2');
// @ts-expect-error Input bigint validation remains strict.
api.wideItems([1]);
// @ts-expect-error Generic stream item input remains precise.
feed.emit({value: 'bad'});
// @ts-expect-error Stream getter remains readonly.
box.values = numbers;
// @ts-expect-error The iterator has no input channel.
numbers.next(1);
void [next, completion, subpath, selected, empty, strings, wide, promises, raw,
  undefineds, getter, method, point, typed, owned, closed, future, adopted, wrongVoid];
