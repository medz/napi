import addon = require('./addon');

const integer: addon.Envelope<number> = addon.echoInt({ value: 7 });
const text: addon.Envelope<string> = addon.echoText({ value: 'hello', optional: 'next' });
const double: addon.Envelope<number> = addon.echoDouble({ value: 3 });
const inferred: addon.Envelope<number> = addon.echo({ value: 3 });
const explicit: addon.Envelope<string> = addon.echo<string>({ value: 'hello' });
const nullable: addon.Envelope<number> | null = addon.nullable();
const point: addon.Envelope<addon.Point> = addon.echoPoint({ value: { value: '3' } });
const pointValue: number = point.value.value;
const bounced = addon.bounce(value => ({ value: { value: String(value.value.value + 1) } }));
const bouncedValue: addon.Envelope<addon.Point> = bounced({ value: { value: '3' } });
const groups: Promise<Record<string, (addon.Envelope<addon.Point> | null)[]>> =
  addon.groups(Promise.resolve({ one: [{ value: { value: '5' } }, null] }));
const readout: addon.Readout<number> = addon.readout();
const nestedReadout: addon.Readout<addon.Readout<number>> = addon.nestedReadout();
const intProducer: addon.Producer<number> = addon.echoIntProducer({ create: () => 7 });
const pointProducer: addon.Producer<addon.Point> = addon.echoPointProducer({
  create: () => ({ value: '9' }),
});
const produced: number = pointProducer.create().value;
const recursive: addon.Recursive<number> = addon.echoRecursive({
  value: 1, next: { value: [2], next: { value: [[3]] } },
});
const nested: number[][] | undefined = recursive.next?.next?.value;

// @ts-expect-error Closed generic constructors retain their concrete input type.
addon.echoInt({ value: '7' });
// @ts-expect-error Generic arguments preserve value relationships.
addon.echo<string>({ value: 3 });
// @ts-expect-error Nullable optional values do not accept explicit undefined.
addon.echoInt({ value: 7, optional: undefined });
// @ts-expect-error The nested constructor consumes String, not the output integer.
addon.echoPoint({ value: { value: 3 } });
// @ts-expect-error Output records do not satisfy the asymmetric input shape.
addon.echoPoint(point);
// @ts-expect-error Callback results use the nested input constructor shape.
addon.bounce(value => value);
// @ts-expect-error A returned adapter still requires the nested input shape.
bounced({ value: { value: 3 } });
// @ts-expect-error Recursive generic arguments transform at each level.
addon.echoRecursive({ value: 1, next: { value: ['wrong'] } });
// @ts-expect-error Data classes are type-only exports.
new addon.Envelope(3);
// @ts-expect-error Producer callbacks return the nested constructor's String input.
addon.echoPointProducer({ create: () => ({ value: 9 }) });
