import assert from 'node:assert/strict';

export function verifyHierarchy(api) {
  const {HierarchyBase: Base, HierarchyChild: Child, HierarchyView: View} = api;
  const before = api.hierarchyConstructions();
  const baseFirst = api.makeHierarchyBase(11);
  assert.equal(api.hierarchyConstructions(), before + 1);
  assert.equal(Object.getPrototypeOf(baseFirst), Child.prototype);
  assert(baseFirst instanceof Base);
  assert(baseFirst instanceof Child);
  assert.equal(api.heldHierarchyChild(), baseFirst);
  assert.equal(api.heldHierarchyBase(), baseFirst);
  const childFirst = api.makeHierarchyChild(13);
  assert.notEqual(childFirst, baseFirst);
  assert.equal(api.heldHierarchyBase(), childFirst);
  assert.equal(api.heldHierarchyChild(), childFirst);
  assert.equal(api.hierarchyConstructions(), before + 2);
  for (const value of [baseFirst, childFirst, new Child(19), Base.child(23)]) {
    assert.equal(Object.getPrototypeOf(value), Child.prototype);
    assert.equal(Object.getPrototypeOf(Child.prototype), Base.prototype);
    assert.equal(api.echoHierarchyBase(value), value);
    assert.equal(api.echoHierarchyChild(value), value);
    assert.equal(api.echoHierarchyView(value), value);
    assert.equal(Base.prototype.self.call(value), value);
    assert.equal(View.prototype.view.call(value), value.value);
    assert.deepEqual(api.hierarchyViews(value), {$1: value, $2: value, $3: value});
    assert.deepEqual(api.hierarchyList([value, value]), [value, value]);
    assert.deepEqual(api.hierarchyEnvelope({base: value, view: value}), {base: value, view: value});
    // Defaults belong to each selected declaration, including undefined holes.
    assert.equal(value.defaults(), 708);
    assert.equal(value.defaults(undefined, 9), 709);
    assert.equal(Base.prototype.defaults.call(value), 102);
    assert.equal(Base.prototype.defaults.call(value, undefined, 9), 109);
    assert.equal(value.named(), 3);
    assert.equal(value.named({amount: undefined}), 3);
    assert.equal(value.named({amount: 9}), 9);
    assert.equal(value.run(), 42);
    assert.equal(Base.prototype.run.call(value), undefined);
  }
  assert.equal(Base.baseOnly(), 'base');
  assert.equal(Child.childOnly(), 'child');
  assert.equal(Child.baseOnly, undefined);
  assert.equal(Child.child, undefined, 'Dart named constructors do not inherit');
  assert.equal(Object.getPrototypeOf(Child), Function.prototype);
  assert.throws(() => new View(), TypeError);

  const getter = new api.HierarchyGetter(2);
  getter.value = 7;
  assert.equal(getter.value, 14);
  const setter = new api.HierarchySetter(2);
  setter.value = 7;
  assert.equal(setter.value, 8);
  const writable = new api.HierarchyWritable();
  assert.equal(writable.value, 1);
  writable.value = 7;
  assert.equal(writable.value, 7);
  for (const type of [api.HierarchyGetter, api.HierarchySetter, api.HierarchyWritable]) {
    const property = Object.getOwnPropertyDescriptor(type.prototype, 'value');
    assert.equal(typeof property.get, 'function');
    assert.equal(typeof property.set, 'function');
    assert.equal(property.get.name, 'get value');
    assert.equal(property.set.name, 'set value');
    assert.equal(Object.hasOwn(property.get, 'prototype'), false);
    assert.equal(Object.hasOwn(property.set, 'prototype'), false);
  }
  api.resetHierarchyFactory();
  const factory = new api.HierarchyFactory();
  assert.equal(Object.getPrototypeOf(factory), api.HierarchyFactoryChild.prototype);
  assert(factory instanceof api.HierarchyFactory);
  assert.equal(factory.child(), 42);
  assert.equal(factory.self(), factory);
  assert.equal(new api.HierarchyFactory(), factory);

  const base = new Base(5);
  for (const invalid of [base, {}, Object.create(Child.prototype), new Proxy(childFirst, {}), null]) {
    assert.throws(() => api.echoHierarchyChild(invalid), TypeError);
    assert.throws(() => Child.prototype.view.call(invalid), TypeError);
  }
  for (const invalid of [{}, Object.create(Base.prototype), new Proxy(childFirst, {}), null]) {
    assert.throws(() => api.echoHierarchyBase(invalid), TypeError);
    assert.throws(() => Base.prototype.self.call(invalid), TypeError);
  }
  assert.throws(() => api.ambiguousHierarchyLeft(), TypeError);
  assert.throws(() => api.ambiguousHierarchyRight(), TypeError);
  assert.equal(new api.HierarchyLeft().left(), 1);
  assert.throws(() => api.failingHierarchy(), RangeError);
  const recovered = api.heldHierarchyChild();
  assert.equal(Object.getPrototypeOf(recovered), Child.prototype);
  assert.equal(api.heldHierarchyBase(), recovered);
  assert.equal(recovered.value, 17);
  api.clearHierarchy();

  const constructions = api.referenceConstructions();
  class JSChild extends api.RefBox {
    #extra = 4;
    extra() { return this.#extra; }
    self() { return super.self(); }
  }
  class JSGrandchild extends JSChild {}
  const js = new JSGrandchild(31);
  assert.equal(api.referenceConstructions(), constructions + 1);
  assert(js instanceof api.RefBox && js instanceof JSChild && js instanceof JSGrandchild);
  assert.equal(Object.getPrototypeOf(js), JSGrandchild.prototype);
  assert.equal(js.constructor, JSGrandchild);
  assert.equal(js.extra(), 4);
  assert.equal(js.self(), js);
  assert.equal(api.RefBox.prototype.self.call(js), js);
  assert.equal(api.identityReference(js), js);
  function OtherTarget() {}
  const other = Reflect.construct(api.RefBox, [37], OtherTarget);
  assert.equal(Object.getPrototypeOf(other), OtherTarget.prototype);
  assert.equal(other instanceof api.RefBox, false);
  assert.equal(api.identityReference(other), other);
  assert.equal(api.RefBox.prototype.self.call(other), other);
  // A cached factory keeps its reachable wrapper ahead of a later newTarget.
  class JSFactory extends api.HierarchyFactory {}
  assert.equal(new JSFactory(), factory);
  api.resetHierarchyFactory();
  class JSFactoryFirst extends api.HierarchyFactory {
    #privateValue = 47;
    privateValue() { return this.#privateValue; }
  }
  const first = new JSFactoryFirst();
  assert.equal(Object.getPrototypeOf(first), JSFactoryFirst.prototype);
  assert.equal(first.privateValue(), 47);
  assert.equal(first.self(), first);
  assert.equal(api.HierarchyFactoryChild.prototype.child.call(first), 42);
  assert.equal(new api.HierarchyFactory(), first);
  const custom = Reflect.construct(Base, [41], OtherTarget);
  assert.equal(Object.getPrototypeOf(custom), OtherTarget.prototype);
  assert.equal(api.echoHierarchyBase(custom), custom);
  class JSBase extends Base {}
  const jsBase = new JSBase(43);
  assert.equal(Object.getPrototypeOf(jsBase), JSBase.prototype);
  assert.equal(jsBase.self(), jsBase);
}

export function verifyForeignHierarchy(api, independent) {
  const foreign = new independent.HierarchyChild(2);
  for (const convert of [api.echoHierarchyBase, api.echoHierarchyChild, api.echoHierarchyView]) {
    assert.throws(() => convert(foreign), TypeError);
  }
  assert.throws(() => api.HierarchyBase.prototype.self.call(foreign), TypeError);
  assert.equal(independent.echoHierarchyBase(foreign), foreign);
}

export async function verifyHierarchyRetention(api) {
  for (let round = 0; round < 6; round++) {
    const before = api.hierarchyConstructions();
    let value = api.makeHierarchyBase(round);
    const weak = new WeakRef(value);
    assert.equal(api.heldHierarchyChild(), value);
    value = null;
    for (let attempt = 0; attempt < 100; attempt++) {
      await new Promise(setImmediate);
      global.gc();
      if (weak.deref() === undefined) break;
    }
    assert.equal(weak.deref(), undefined, 'Dart-held object must not root its wrapper');
    const adopted = api.heldHierarchyChild();
    assert.equal(Object.getPrototypeOf(adopted), api.HierarchyChild.prototype);
    assert.equal(api.heldHierarchyBase(), adopted);
    assert.equal(api.echoHierarchyView(adopted), adopted);
    assert.equal(adopted.value, round);
    assert.equal(api.hierarchyConstructions(), before + 1, 'readoption must not construct Dart objects');
    await new Promise(setImmediate);
    global.gc();
    assert.equal(api.heldHierarchyBase(), adopted, 'delayed old finalizer must not invalidate replacement');
    api.clearHierarchy();
  }
}
