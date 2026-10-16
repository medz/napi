import assert from 'node:assert/strict';

export function verifyClasses({Counter, Other, Scalars, Options, RefBox, NamedReference}) {
  for (const type of [Counter, Other, Scalars, Options, RefBox, NamedReference]) {
    // Real class constructors retain [[Construct]]. Methods and accessor
    // functions must reject use as newTarget before running any Dart callback.
    assert(Object.hasOwn(type, 'prototype'));
    assert.equal(Object.getPrototypeOf(Reflect.construct(Object, [], type)), type.prototype);
    for (const target of [type, type.prototype]) {
      for (const [name, descriptor] of Object.entries(Object.getOwnPropertyDescriptors(target))) {
        if (target === type.prototype && name === 'constructor') continue;
        const functions = [descriptor.value, descriptor.get, descriptor.set].filter(value => typeof value === 'function');
        if (functions.length === 0) continue;
        assert.equal(descriptor.enumerable, false);
        assert.equal(descriptor.configurable, true);
        if (descriptor.value) {
          assert.equal(descriptor.writable, true);
          assert.equal(descriptor.value.name, name);
        }
        if (descriptor.get) assert.equal(descriptor.get.name, `get ${name}`);
        if (descriptor.set) assert.equal(descriptor.set.name, `set ${name}`);
        for (const fn of functions) {
          assert.equal(Object.hasOwn(fn, 'prototype'), false, `${name} must not expose a function prototype`);
          assert.throws(() => Reflect.construct(Object, [], fn), TypeError);
          assert.throws(() => Reflect.construct(Object, [], fn.bind(null)), TypeError);
          assert.throws(() => new fn(), TypeError);
        }
      }
    }
  }
  assert.equal(Counter.length, 0);
  assert.equal(Counter.prototype.increment.length, 0);
  assert.equal(Scalars.prototype.echo.length, 1);
  assert.equal(Counter.label.length, 0);
  assert.equal(RefBox.from.length, 1);
  assert.equal(RefBox.shared.length, 0);
  assert.equal(NamedReference.make.length, 1);
  const descriptor = Object.getOwnPropertyDescriptor(Counter.prototype, 'value');
  assert.equal(descriptor.get.length, 0);
  assert.equal(descriptor.set.length, 1);
  const one = new Counter();
  const two = new Counter(undefined);
  assert(one instanceof Counter);
  assert.equal(one.value, 0);
  assert.equal(one.increment(), 1);
  assert.equal(one.increment(undefined), 2);
  assert.equal(one.increment(0), 2);
  assert.equal(one.named({amount: 3}), 5);
  assert.equal(one.named({amount: undefined}), 7);
  assert.equal(one.requiredNamed({amount: null}), 7);
  assert.equal(one.doubleValue(), 14);
  assert.equal(two.value, 0);
  one.value = 41;
  assert.equal(one.increment(), 42);
  assert.equal(Counter.label(), 'Dart Counter');
  Counter.count = 12;
  assert.equal(Counter.count, 12);
  assert.throws(() => { Counter.count = 'bad'; }, TypeError);
  assert.equal(Counter.count, 12);
  assert.equal(one.hidden, undefined);
  assert.equal(new Other().value, 4);
  assert.throws(() => { new Other().value = 3; }, TypeError);
  assert.throws(() => Counter(), TypeError);
  assert.throws(() => new Counter(null), TypeError);
  assert.throws(() => new Counter(2n), TypeError);
  assert.throws(() => new Counter(1.5), RangeError);
  assert.throws(() => new Counter(-999), /constructor failed/);
  assert.throws(() => { one.value = '1'; }, TypeError);
  assert.equal(one.value, 42);
  let accessorReads = 0;
  assert.throws(() => one.named({get amount() { accessorReads++; return 1; }}), TypeError);
  assert.equal(accessorReads, 0);
  assert.throws(() => one.named({unexpected: 1}), TypeError);
  assert.throws(() => one.requiredNamed(), TypeError);
  assert.throws(() => one.requiredNamed({amount: undefined}), TypeError);
  assert.throws(() => one.increment(0.5), RangeError);
  assert.equal(one.value, 42);
  for (const receiver of [{}, Object.create(Counter.prototype), new Other(), null, new Proxy(one, {})]) {
    assert.throws(() => Counter.prototype.increment.call(receiver), TypeError);
    assert.throws(() => descriptor.get.call(receiver), TypeError);
    assert.throws(() => descriptor.set.call(receiver, 1), TypeError);
  }
  const increment = one.increment;
  assert.throws(() => increment(), TypeError);
  assert.equal(increment.call(one), 43);
  assert.throws(() => one.fail(), error => error.constructor === Error && /method failed/.test(error.message));
  assert.throws(() => one.badDescription(), /description unavailable/);
  assert.equal(one.value, 43);
  assert.equal(one.reset(), undefined);
  assert.equal(one.value, 0);
  const scalars = new Scalars();
  assert.equal(scalars.empty, undefined);
  assert.equal(Scalars.constructor(), 42);
  const text = '雪\u0000\ud800🙂';
  scalars.enabled = false;
  scalars.text = text;
  scalars.number = -0;
  scalars.integer = (1n << 150n) + 3n;
  scalars.nullable = null;
  assert.equal(scalars.enabled, false);
  assert.equal(scalars.text, text);
  assert(Object.is(scalars.number, -0));
  assert.equal(scalars.integer, (1n << 150n) + 3n);
  assert.equal(scalars.nullable, null);
  scalars.number = NaN;
  assert(Number.isNaN(scalars.number));
  scalars.number = Infinity;
  assert.equal(scalars.number, Infinity);
  scalars.nullable = 0;
  assert.equal(scalars.nullable, 0);
  assert.equal(scalars.echo(text), text);
  assert.equal(scalars.safe(Number.MAX_SAFE_INTEGER), Number.MAX_SAFE_INTEGER);
  assert.equal(scalars.arbitrary(-1n << 180n), -1n << 180n);
  assert.throws(() => scalars.safe(Number.MAX_SAFE_INTEGER + 1), RangeError);
  for (const [key, bad] of [['enabled', 0], ['text', 1], ['number', '1'], ['integer', 1], ['nullable', undefined]]) {
    assert.throws(() => { scalars[key] = bad; }, TypeError);
  }
  const options = new Options({amount: null});
  assert.equal(options.label, 'default');
  assert.equal(options.amount, null);
  assert.equal(new Options({label: undefined, amount: 0}).label, 'default');
  assert.throws(() => new Options(), TypeError);
  assert.throws(() => new Options({amount: undefined}), TypeError);
  assert.throws(() => new Options({amount: null, extra: true}), TypeError);
  for (let i = 0; i < 100; i++) assert.equal(new Counter(i).increment(), i + 1);
  global.gc?.();
  assert.equal(one.increment(), 1);
}
