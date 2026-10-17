import assert from 'node:assert/strict';

export function verifyReferenceViews(api) {
  const before = api.compositeConstructions();
  const read = api.makeReadView(11);
  const prototype = Object.getPrototypeOf(read);
  assert.equal(Object.getPrototypeOf(prototype), Object.prototype);
  assert.equal(read.constructor, Object);
  assert.equal(read instanceof api.ReadView, false);
  assert.equal(read instanceof api.WriteView, false);
  assert.equal(read instanceof api.ExtraView, false);
  assert.equal(api.heldWriteView(), read);
  assert.equal(api.heldExtraView(), read);
  const write = api.makeWriteView(13);
  assert.notEqual(write, read);
  assert.equal(Object.getPrototypeOf(write), prototype);
  assert.equal(api.heldReadView(), write);
  assert.equal(api.heldExtraView(), write);
  const constructed = new api.ReadView(17);
  assert.equal(api.compositeConstructions(), before + 3);
  for (const value of [read, write, constructed]) {
    assert.equal(Object.getPrototypeOf(value), prototype);
    assert.equal(api.echoReadView(value), value);
    assert.equal(api.echoWriteView(value), value);
    assert.equal(api.echoExtraView(value), value);
    assert.equal(value.self(), value);
    assert.deepEqual(api.compositeViews(value), {$1: value, $2: value, $3: value});
    assert.deepEqual(api.compositeList([value, value]), [value, value]);
    value.value = 19;
    assert.equal(value.value, 19);
    assert.equal(value.describe(), 'value=19');
    assert.equal(value.extra(), 38);
    // Defaults use the maximal selected views, not the private override or
    // the overridden ReadBase declaration.
    assert.equal(value.shared(), 26);
    assert.equal(value.shared(undefined), 26);
    assert.equal(api.ReadBase.prototype.shared.call(value), 20);
    assert.equal(api.WriteView.prototype.shared.call(value), 26);
    assert.equal(api.ExtraView.prototype.extra.call(value), 38);
    assert.equal(value.readOnlyStatic, undefined);
  }
  const property = Object.getOwnPropertyDescriptor(prototype, 'value');
  assert.equal(typeof property.get, 'function');
  assert.equal(typeof property.set, 'function');
  assert.equal(property.enumerable, false);
  for (const method of [read.shared, read.describe, property.get, property.set]) {
    assert.equal(Object.hasOwn(method, 'prototype'), false);
    assert.throws(() => Reflect.construct(Object, [], method), TypeError);
  }
  for (const invalid of [{}, Object.create(prototype), new Proxy(read, {}), null]) {
    assert.throws(() => api.echoReadView(invalid), TypeError);
    assert.throws(() => api.echoWriteView(invalid), TypeError);
    assert.throws(() => api.ExtraView.prototype.extra.call(invalid), TypeError);
  }
  for (const conflict of [api.conflictingDefaultsA, api.conflictingDefaultsB, api.conflictingAliases]) {
    assert.throws(conflict, TypeError);
    assert.throws(conflict, TypeError, 'a failed registration must not cache a partial shape');
  }
  assert.throws(() => api.failingComposite(), RangeError);
  const recovered = api.heldWriteView();
  assert.equal(recovered, api.heldReadView());
  assert.equal(Object.getPrototypeOf(recovered), prototype);
  assert.equal(recovered.value, 23);
  assert.equal(recovered.extra(), 46);

  class JSRead extends api.ReadView {
    #private = 5;
    privateValue() { return this.#private; }
    shared(value) { return super.shared(value) + 1; }
  }
  class JSGrandchild extends JSRead {}
  const custom = new JSGrandchild(29);
  assert.equal(Object.getPrototypeOf(custom), JSGrandchild.prototype);
  assert.equal(custom.privateValue(), 5);
  assert.equal(custom.shared(), 37);
  assert.equal(custom.self(), custom);
  assert.equal(custom.describe, undefined, 'explicit JS prototypes may hide unrelated members');
  assert.equal(api.echoWriteView(custom), custom);
  assert.equal(api.WriteView.prototype.describe.call(custom), 'value=29');
  function OtherTarget() {}
  const other = Reflect.construct(api.ReadView, [31], OtherTarget);
  assert.equal(Object.getPrototypeOf(other), OtherTarget.prototype);
  assert.equal(api.echoExtraView(other), other);
  assert.equal(api.ExtraView.prototype.extra.call(other), 62);
  api.clearComposite();
}

export function verifyForeignReferenceViews(api, independent) {
  const foreign = independent.makeReadView(5);
  for (const convert of [api.echoReadView, api.echoWriteView, api.echoExtraView]) {
    assert.throws(() => convert(foreign), TypeError);
  }
  assert.throws(() => api.ReadView.prototype.self.call(foreign), TypeError);
  independent.clearComposite();
}

export async function verifyReferenceViewRetention(api) {
  for (let round = 0; round < 6; round++) {
    const before = api.compositeConstructions();
    let value = api.makeWriteView(round);
    const prototype = Object.getPrototypeOf(value);
    const weak = new WeakRef(value);
    value = null;
    for (let attempt = 0; attempt < 100; attempt++) {
      await new Promise(setImmediate);
      global.gc();
      if (weak.deref() === undefined) break;
    }
    assert.equal(weak.deref(), undefined, 'composite metadata must not retain wrappers');
    const adopted = api.heldReadView();
    assert.equal(api.heldWriteView(), adopted);
    assert.equal(api.heldExtraView(), adopted);
    assert.equal(Object.getPrototypeOf(adopted), prototype);
    assert.equal(adopted.value, round);
    assert.equal(adopted.extra(), round * 2);
    assert.equal(api.compositeConstructions(), before + 1);
    await new Promise(setImmediate);
    global.gc();
    assert.equal(api.heldWriteView(), adopted, 'old finalizers must not release a new lease');
    api.clearComposite();
  }
}
