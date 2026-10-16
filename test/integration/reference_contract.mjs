import assert from 'node:assert/strict';

export function verifyReferences(api) {
  const {RefBox, Once, NamedReference, RefChild} = api;
  const before = api.referenceConstructions();
  const box = new RefBox(17);
  const other = RefBox.from(23);
  assert.equal(api.referenceConstructions(), before + 2);
  assert.equal(box.value, 17);
  assert.equal(other.value, 23);
  assert.notEqual(box, other);
  assert.equal(box.self(), box);
  assert.equal(box.choose(other), other);
  assert.equal(RefBox.echo(box), box);
  assert.equal(api.identityReference(box), box);
  assert.equal(api.nullableReference(box), box);
  assert.equal(api.nullableReference(null), null);
  assert.equal(api.optionalReference(), null);
  assert.equal(api.optionalReference(undefined), null);
  assert.equal(api.optionalReference(box), box);
  assert.equal(api.namedReference({value: box}), box);
  assert.equal(api.namedReference({value: null}), null);
  assert.equal(box.optional(), null);
  assert.equal(box.optional(other), other);
  box.peer = other;
  assert.equal(box.peer, other);
  box.peer = null;
  assert.equal(box.peer, null);
  assert.equal(api.referenceConstructions(), before + 2, 'adoption must not construct again');
  const named = NamedReference.make(box);
  assert(named instanceof NamedReference);
  assert.equal(named.box, box);
  assert.throws(() => new NamedReference(), TypeError);
  const shared = RefBox.shared();
  assert.equal(RefBox.shared(), shared);
  assert.equal(shared.self(), shared);
  assert.equal(shared.value, 42);
  const once = new Once();
  assert.equal(new Once(), once);
  assert.equal(once.self(), once);
  assert.throws(() => Once(), TypeError);
  assert.throws(() => new RefBox.from(0), TypeError);
  for (const bad of [undefined, null, {}, Object.create(RefBox.prototype), new Once(), new Proxy(box, {})]) {
    assert.throws(() => api.identityReference(bad), TypeError);
    assert.throws(() => box.choose(bad), TypeError);
    assert.throws(() => RefBox.echo(bad), TypeError);
  }
  assert.throws(() => api.nullableReference(), TypeError);
  assert.throws(() => api.namedReference({value: undefined}), TypeError);
  assert.throws(() => api.namedReference({}), TypeError);
  assert.throws(() => { box.peer = undefined; }, TypeError);
  // One object cannot silently acquire two selected public class brands.
  assert.throws(() => new RefChild().asBase(), TypeError);
  assert.throws(() => api.identityBase(new RefChild()), TypeError);
  const base = new api.RefBase();
  assert.equal(api.identityBase(base), base);
}

export function verifyForeignReferences(api, independent) {
  const foreign = new independent.RefBox(91);
  assert.throws(() => api.identityReference(foreign), TypeError);
  assert.throws(() => new api.RefBox().choose(foreign), TypeError);
  assert.throws(() => independent.identityReference(new api.RefBox()), TypeError);
  assert.equal(independent.identityReference(foreign), foreign);
}

export async function verifyReferenceRetention(api) {
  assert.equal(typeof global.gc, 'function');
  // Descriptor reflection can reenter the same module and trigger a finalizer
  // while a native Dart callback is suspended inside an FFI call.
  for (let round = 0; round < 4; round++) {
    let dropped = new api.RefBox(round);
    const weak = new WeakRef(dropped);
    dropped = null;
    const live = new api.RefBox(55);
    const options = new Proxy({value: live}, {
      getOwnPropertyDescriptor(target, key) {
        global.gc();
        assert.equal(api.identityReference(live), live);
        return Reflect.getOwnPropertyDescriptor(target, key);
      },
    });
    for (let attempt = 0; attempt < 100; attempt++) {
      await new Promise(resolve => setImmediate(resolve));
      assert.equal(api.namedReference(options), live);
      assert.equal(live.self(), live);
      if (weak.deref() === undefined) break;
    }
    assert.equal(weak.deref(), undefined, 'GC inside reflection must release dropped wrappers');
  }
  // Dart deliberately keeps the object alive while its JS wrapper is dropped.
  // Repeated adoption exercises distinct leases and delayed old finalizers.
  const before = api.referenceConstructions();
  let box = new api.RefBox(31);
  api.holdReference(box);
  for (let round = 0; round < 12; round++) {
    const weak = new WeakRef(box);
    box = null;
    let collected = false;
    for (let attempt = 0; attempt < 100; attempt++) {
      await new Promise(resolve => setImmediate(resolve));
      global.gc();
      if (weak.deref() === undefined) { collected = true; break; }
    }
    assert(collected, 'identity cache must not keep an unreferenced wrapper alive');
    box = api.heldReference();
    assert(box instanceof api.RefBox);
    assert.equal(box.value, 31 + round);
    box.value++;
    assert.equal(api.heldReference(), box);
    await new Promise(resolve => setImmediate(resolve));
    global.gc();
    assert.equal(box.self(), box, 'old finalizers must not release a new lease');
  }
  api.holdReference(null);
  assert.equal(box.value, 43, 'a live wrapper retains its Dart owner');
  assert.equal(api.referenceAlive(), true);
  assert.equal(api.referenceConstructions(), before + 1, 'adoption skips business construction');
  const weak = new WeakRef(box);
  box = null;
  for (let attempt = 0; attempt < 100; attempt++) {
    await new Promise(resolve => setImmediate(resolve));
    global.gc();
    api.referencePressure(attempt);
    if (weak.deref() === undefined && !api.referenceAlive()) return;
  }
  assert.fail('unheld wrapper and its Dart object must be collectable');
}
