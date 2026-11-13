import * as addon from './addon';

const values: Iterable<number> = addon.sequence();
for (const value of values) {
  const number: number = value;
}
addon.first([1, 2]);
addon.take(new Set([1, 2]), 1);
addon.strings('text');
const nullable: Iterable<number> | null = addon.nullable();
const future: Promise<Iterable<number>> = addon.later();
const objects = addon.points([{ x: 1 }]);
const points: Iterable<addon.Point> = objects;
const amounts: Iterable<addon.Amount> = addon.amounts([{ value: '2' }]);
// @ts-expect-error The constructor takes strings even though output fields are numbers.
addon.amounts([{ value: 2 }]);
const identity: Iterable<{ id: number }> = addon.echo([{ id: 1 }]);
addon.callback(function* (source) {
  for (const value of source) yield value + 1;
});
// @ts-expect-error Elements must satisfy the declared Dart type.
addon.first(['wrong']);
// @ts-expect-error A non-nullable iterable cannot be null.
addon.first(null);
// @ts-expect-error An iterable callback must return numbers.
addon.callback(() => ['wrong']);
