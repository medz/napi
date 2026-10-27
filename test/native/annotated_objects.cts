import addon = require('./addon');

const child = new addon.PointInput(5);
const point: addon.Point = addon.echoPoint({ value: '7', child, next: { value: '8' } });
const value: number = point.value;
const title: string = point.title;
const note: string | null = point.note;
const next: addon.Point | null = point.next;
const bound: addon.PointInput | null = point.child;
point.value = 9;
point.title = 'writable copy';
const offset: addon.Offset = addon.echoOffset({ y: 9 });
const readout: addon.Readout = addon.readout();
const once: number[] | null = readout.values;
const transformed: addon.Point = addon.transformPoint({ value: '3' }, value => ({ value: String(value.value) }));
const bounced = addon.bouncePoint(value => ({ value: String(value.value + 1) }));
const bouncedPoint: addon.Point = bounced({ value: '7' });
const bouncedPoints = addon.bouncePoints([value => ({ value: String(value.value) })]);
const nestedPoint: addon.Point = bouncedPoints[0]({ value: '9' });
const streamFactory: () => AsyncIterableIterator<number> = addon.bounceStream(() => ({
  async *[Symbol.asyncIterator]() { yield 7; },
}));
const entries: Promise<{ key: string; point: addon.Point }[]> =
  addon.pointEntries(Promise.resolve({ one: { value: '1' } }));
const stream: AsyncIterableIterator<addon.Point> = addon.pointStream({ value: '2' });

// @ts-expect-error Structural class names only exist as TypeScript interfaces.
new addon.Point();
// @ts-expect-error Output-only class names have no runtime constructor.
new addon.Readout();
// @ts-expect-error Constructor parameters define the input shape.
addon.echoPoint({ value: 7 });
// @ts-expect-error Output records are not accepted as asymmetric constructor input.
addon.echoPoint(point);
// @ts-expect-error Required constructor parameters stay required.
addon.echoPoint({});
// @ts-expect-error Output aliases do not rename constructor parameters.
addon.echoPoint({ value: '7', title: 'wrong input name' });
// @ts-expect-error Optional nullable constructor inputs exclude undefined.
addon.echoPoint({ value: '7', note: undefined });
// @ts-expect-error Recursive input shapes retain constructor parameter types.
addon.echoPoint({ value: '7', next: { value: 8 } });
// @ts-expect-error Bound children retain nominal class types.
addon.echoPoint({ value: '7', child: { value: 5 } });
// @ts-expect-error Callback results flow into the input constructor shape.
addon.transformPoint({ value: '3' }, value => value);
// @ts-expect-error Returned adapters accept constructor input, not output records.
bounced({ value: 7 });
// @ts-expect-error Callback results use the constructor's String input type.
addon.bouncePoint(value => ({ value: value.value }));
// @ts-expect-error Nested function adapters retain their input signature.
bouncedPoints[0]({ value: 9 });
// @ts-expect-error Output fields retain their getter types.
point.value = '9';
