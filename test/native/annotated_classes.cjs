'use strict';

const assert = require('node:assert/strict');
const { setImmediate: nextTurn } = require('node:timers/promises');

module.exports = async function verifyAnnotatedClasses(path) {
  const { Counter, Other, FactoryCounter, NamedOnly, Visibility, ReturnedOnly,
    echoCounter, echoNullableCounter, derived, sharedCounter, multiCounter, multiOther,
    returnedOnly } = require(path);
  Counter.created = 0;
  const a = new Counter();
  const b = new Counter(5);
  assert(a instanceof Counter);
  assert.equal(a.increment(), 1);
  assert.equal(b.increment(2), 7);
  assert.equal(a.value, 1);
  assert.equal(a.peer, null);
  a.peer = b;
  assert.equal(a.peer, b);
  a.peer = null;
  assert.equal(a.peer, null);
  assert.throws(() => { a.peer = new Other(); }, TypeError);
  assert.throws(() => { a.peer = undefined; }, TypeError);
  assert.equal(a.peer, null);
  a.value = 10;
  assert.equal(a.doubled, 20);
  a.doubled = 42;
  assert.equal(a.value, 21);
  assert.equal(a.kind, 'counter');
  assert.throws(() => { a.kind = 'other'; }, TypeError);
  assert.equal(a.note, null);
  a.note = '中文';
  assert.equal(a.note, '中文');
  a.note = null;
  assert.equal(a.note, null);
  assert.throws(() => { a.note = undefined; }, TypeError);
  assert.equal(a.same(), a);
  assert.equal(echoCounter(a), a);
  assert.equal(echoNullableCounter(a), a);
  assert.equal(echoNullableCounter(), null);
  assert.equal(echoNullableCounter(null), null);
  assert.throws(() => echoNullableCounter(undefined), TypeError);
  assert.equal(a._reset, undefined);
  assert.equal(Counter._limit, undefined);
  a.reset(4);
  assert.equal(a.value, 4);
  a.reset();
  assert.equal(a.value, 0);

  const beforeFactory = Counter.created;
  const named = Counter.named({ value: 6, note: null });
  assert(named instanceof Counter);
  assert.equal(named.value, 6);
  assert.equal(named.note, null);
  assert.equal(Counter.created, beforeFactory + 1);
  assert.equal(Counter.named().value, 5);
  assert.throws(() => Counter.named({ value: undefined }), TypeError);
  assert.throws(() => new Counter(undefined), TypeError);
  assert.throws(() => Counter(), TypeError);
  const beforeZero = Counter.created;
  const zero = Counter.zero;
  assert.equal(zero().value, 0);
  assert.equal(Counter.created, beforeZero + 1);
  Counter.limit = 17;
  assert.equal(Counter.limit, 17);
  assert.throws(() => { Counter.limit = undefined; }, TypeError);
  assert.throws(() => { Counter.limit = -1; }, RangeError);
  assert.equal(Counter.limit, 17);

  const factory = new FactoryCounter();
  assert(factory instanceof FactoryCounter);
  assert.equal(factory.value, 3);
  assert.equal(new FactoryCounter(9).value, 9);
  assert.throws(() => new NamedOnly(), TypeError);
  const namedOnly = NamedOnly.create();
  assert(namedOnly instanceof NamedOnly);
  assert.equal(namedOnly.value, 4);

  const visible = new Visibility();
  assert.equal(visible.id, 7);
  assert.throws(() => { visible.id = 9; }, TypeError);
  assert.equal(visible.lazy, 11);
  assert.throws(() => { visible.lazy = 13; }, TypeError);
  assert.equal(visible.lazy, 11);
  for (const name of ['hiddenField', 'hiddenMethod', 'hiddenAccessor', 'unsupported', 'unsupportedMethod']) {
    assert.equal(name in visible, false);
  }
  for (const name of ['named', 'hidden', 'hiddenStaticField', 'hiddenStaticMethod']) {
    assert.equal(Object.hasOwn(Visibility, name), false);
  }
  const reader = Object.getOwnPropertyDescriptor(Visibility.prototype, 'readOnly');
  assert.equal(typeof reader.get, 'function');
  assert.equal(reader.set, undefined);
  assert.equal(visible.readOnly, 3);
  assert.throws(() => { visible.readOnly = 9; }, TypeError);
  assert.equal(visible.readOnly, 3);
  const writer = Object.getOwnPropertyDescriptor(Visibility.prototype, 'writeOnly');
  assert.equal(writer.get, undefined);
  assert.equal(typeof writer.set, 'function');
  assert.equal(visible.writeOnly, undefined);
  visible.writeOnly = 23;
  assert.equal(visible.readStored(), 23);
  assert.equal(visible.writeOnly, undefined);
  assert.throws(() => new ReturnedOnly(1), TypeError);
  const returned = returnedOnly();
  assert(returned instanceof ReturnedOnly);
  assert.equal(returned.value, 19);
  assert.equal(returned.read(), 19);

  const { get, set } = Object.getOwnPropertyDescriptor(Counter.prototype, 'value');
  for (const value of [{}, Object.create(Counter.prototype), new Other()]) {
    assert.throws(() => echoCounter(value), TypeError);
    assert.throws(() => Counter.prototype.increment.call(value), TypeError);
    assert.throws(() => get.call(value), TypeError);
    assert.throws(() => set.call(value, 1), TypeError);
  }
  const child = derived();
  assert(child instanceof Counter);
  assert.equal(child.increment(), 2);
  assert.equal(child.increment(5), 7);
  assert.equal(child.namedStep(), '3|derived');
  assert.equal(child.namedStep({ note: 'explicit' }), '3|explicit');
  assert.equal(child.namedStep({ step: 9 }), '9|derived');
  assert.equal(child.namedStep({ step: 9, note: 'explicit' }), '9|explicit');
  assert.equal(echoCounter(child), child);

  const firstView = multiCounter();
  assert(firstView instanceof Counter);
  assert.throws(() => multiOther(), /already bound/);
  assert.equal(multiCounter(), firstView);
  assert.equal(firstView.increment(), 1);

  let shared = sharedCounter();
  assert(shared instanceof Counter);
  assert.equal(sharedCounter(), shared);
  assert.equal(shared.increment(3), 11);
  const beforeRewrap = Counter.created;
  const weak = new WeakRef(shared);
  shared = null;
  for (let i = 0; i < 32; ++i) {
    await nextTurn();
    global.gc();
    await nextTurn();
    if (weak.deref() === undefined) break;
  }
  assert.equal(weak.deref(), undefined, 'Class identity cache kept its JS wrapper alive');
  const rewrapped = sharedCounter();
  assert(rewrapped instanceof Counter);
  assert.equal(rewrapped.value, 11);
  assert.equal(sharedCounter(), rewrapped);
  assert.equal(Counter.created, beforeRewrap);
  assert.equal(a.increment(), 1);
};
