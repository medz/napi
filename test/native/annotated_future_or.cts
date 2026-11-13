import addon = require('./addon');

const sync: number | Promise<number> = addon.echo(3);
const async: number | Promise<number> = addon.echo(Promise.resolve(4));
const nullable: number | null | Promise<number | null> = addon.nullable(null);
const optional: number | Promise<number> | null = addon.optional();
const ignored: void | Promise<void> = addon.ignored(undefined);
const futureValue: Promise<number> = addon.futureValue(Promise.resolve(6));
const envelope: addon.Envelope<Promise<number>> = addon.envelope({ value: Promise.resolve(7) });
const values: (number | Promise<number>)[] = addon.values([1, Promise.resolve(2)]);
const applied: number | Promise<number> = addon.apply(value => value + 1);
addon.apply(async value => value + 1);
const callback: (value: number | Promise<number>) => number | Promise<number> = addon.callback();
const amount: addon.Amount | Promise<addon.Amount> = addon.amount({ value: '42' });
addon.amount(Promise.resolve({ value: '42' }));
const amountEnvelope: addon.Envelope<addon.Amount> = addon.amountEnvelope({ value: Promise.resolve({ value: '42' }) });
const box: addon.Box<number | Promise<number>> = addon.box(false);
box.value = 3;
box.value = Promise.resolve(4);
addon.generic(value => value);
addon.boxed(box => { const value: unknown = box.value; });
const thenable: addon.Thenable | Promise<number | addon.Thenable> = addon.thenable(true, false);
addon.echoThenable({ then: (resolve: (value: number) => void) => resolve(12) });
addon.echoThenable(Promise.resolve({ then: Promise.resolve((resolve: (value: number) => void) => resolve(12)) }));

// @ts-expect-error Both branches retain the declared element type.
addon.echo('3');
// @ts-expect-error A Promise must fulfill with the declared element type.
addon.echo(Promise.resolve('3'));
// @ts-expect-error FutureOr inputs require a value or a real Promise, not PromiseLike.
addon.echo({ then(resolve: (value: number) => void) { resolve(3); } });
// @ts-expect-error Optional null does not include undefined.
addon.optional(undefined);
// @ts-expect-error Sync callbacks also retain their result type.
addon.apply(() => 'wrong');
// @ts-expect-error Async callbacks also retain their result type.
addon.apply(async () => 'wrong');
// @ts-expect-error Constructor inputs remain distinct from output fields.
addon.amount({ value: 42 });
// @ts-expect-error Promise inputs use the constructor input type too.
addon.amount(Promise.resolve({ value: 42 }));
// @ts-expect-error Generic object fields retain their constructor input shape.
addon.amountEnvelope({ value: Promise.resolve({ value: 42 }) });
// @ts-expect-error The box keeps both branches typed.
box.value = Promise.resolve('wrong');
declare const adopted: Promise<addon.Thenable>;
// @ts-expect-error A callable then is adopted before a Promise can reach Dart.
addon.echoThenable(adopted);
