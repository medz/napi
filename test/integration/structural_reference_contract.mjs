import assert from 'node:assert/strict';

function typeAt(call, path) {
  assert.throws(call, error => error instanceof TypeError && error.message.startsWith(path + ':'));
}

export function verifyStructuralReferences(api) {
  const {RefBox, RefCollection} = api;
  const before = api.referenceConstructions();
  const box = new RefBox(12);
  const other = new RefBox(23);
  const peers = [box, null, other];
  const row = {$1: box, peers};
  const source = [row, null, row];
  const output = api.echoReferenceRows(source);
  assert.notEqual(output, source);
  assert.notEqual(output[0], row);
  assert.notEqual(output[0], output[2]);
  assert.notEqual(output[0].peers, output[2].peers);
  assert.equal(output[0].$1, box);
  assert.equal(output[2].$1, box);
  assert.deepEqual(output[0].peers, peers);
  assert.equal(output[0].peers[0], box);
  assert.equal(api.identityReference(output[0].$1), box);
  assert.deepEqual(api.mixedReferenceRows(other, peers), [other, ...peers]);
  output[0].peers.pop();
  assert.equal(peers.length, 3);
  assert.equal(output[2].peers.length, 3);
  box.value++;
  assert.equal(output[0].$1.value, 13, 'cloned containers retain their reference leaves');
  assert.deepEqual(api.echoReferenceRows([{$1: box, peers: null}]), [{$1: box, peers: null}]);

  const calls = api.structuralReferenceCalls();
  for (const bad of [undefined, null, {}, new api.Once(), Object.create(RefBox.prototype), new Proxy(box, {})]) {
    typeAt(() => api.echoReferenceRows([row, {$1: bad, peers: null}]), 'echoReferenceRows.value[1].$1');
  }
  typeAt(() => api.echoReferenceRows([{$1: box, peers: [other, undefined]}]), 'echoReferenceRows.value[0].peers[1]');
  assert.equal(api.structuralReferenceCalls(), calls, 'later failure prevents Dart business invocation');
  assert.equal(api.echoReferenceRows([row])[0].$1, box);
  for (let i = 0; i < 3; i++) {
    assert.throws(() => api.invalidReferenceRow(box), error => error instanceof RangeError && error.message.startsWith('invalidReferenceRow result.$2:'));
    global.gc?.();
    assert.equal(api.identityReference(box), box);
    assert.equal(api.echoReferenceRows([row])[0].$1, box);
  }

  const collection = new RefCollection(peers, {counts: [1, null]});
  assert(collection instanceof RefCollection);
  assert.deepEqual(collection.values, peers);
  assert.notEqual(collection.values, collection.values);
  assert.deepEqual(collection.counts, [1, null]);
  assert.throws(() => { collection.counts = []; }, TypeError);
  collection.values = [other, box];
  assert.deepEqual(collection.values, [other, box]);
  assert.deepEqual(collection.replace(peers), peers);
  assert.deepEqual(collection.named({value: peers}), peers);
  assert.deepEqual(RefCollection.duplicate(peers), peers);
  assert.deepEqual(RefCollection.fromRows(peers).values, peers);
  assert.equal(collection.row, null);
  collection.row = {$1: box, peers: [other]};
  assert.equal(collection.row.$1, box);
  assert.equal(collection.row.peers[0], other);
  const copied = collection.row;
  copied.peers.length = 0;
  assert.equal(collection.row.peers[0], other);
  collection.row = null;
  assert.equal(collection.row, null);
  assert.equal(collection.optional(), null);
  assert.equal(collection.optional(undefined), null);
  assert.equal(collection.optional(null), null);
  assert.deepEqual(collection.optional([1, null]), [1, null]);
  assert.throws(() => collection.named({}), TypeError);
  assert.throws(() => { collection.values = [new api.Once()]; }, TypeError);
  assert.deepEqual(collection.values, peers, 'failed setters leave Dart state intact');
  assert.equal(api.referenceConstructions(), before + 2, 'structural conversion never constructs a reference leaf');

  // Traps may reenter the same runtime during a partially converted container.
  const reentrant = new Proxy([box, other], {
    getOwnPropertyDescriptor(target, key) {
      global.gc?.();
      assert.equal(api.identityReference(box), box);
      return Reflect.getOwnPropertyDescriptor(target, key);
    },
  });
  assert.deepEqual(RefCollection.duplicate(reentrant), [box, other]);

  // A failed result must not choose a public brand for an unreturned object.
  for (const fail of [api.failingReferenceList, api.failingReferenceScalar]) {
    for (let round = 0; round < 3; round++) {
      assert.throws(fail, Error);
      global.gc?.();
      const child = api.partialReferenceChild();
      assert(child instanceof api.RefChild);
      assert.equal(api.partialReferenceChild(), child);
    }
  }
  // A prior successful exposure keeps its brand even when a later output fails.
  const exposed = api.createPartialReferenceBase();
  assert(exposed instanceof api.RefBase);
  assert.throws(() => api.failingExistingReferenceScalar(exposed), RangeError);
  global.gc?.();
  assert.equal(api.identityBase(exposed), exposed);
  assert.throws(() => api.partialReferenceChild(), TypeError);
}

export function verifyForeignStructuralReferences(api, independent) {
  const foreign = new independent.RefBox(19);
  typeAt(() => api.echoReferenceRows([{$1: foreign, peers: null}]), 'echoReferenceRows.value[0].$1');
  const local = new api.RefBox(7);
  typeAt(() => api.echoReferenceRows([{$1: local, peers: [foreign]}]), 'echoReferenceRows.value[0].peers[0]');
  assert.equal(independent.echoReferenceRows([{$1: foreign, peers: null}])[0].$1, foreign);
}

export async function verifyStructuralReferenceRetention(api) {
  assert.equal(typeof global.gc, 'function');
  const before = api.referenceConstructions();
  let box = new api.RefBox(81);
  let source = [{$1: box, peers: [box, null]}];
  api.holdReferenceRows(source);
  source.length = 0;
  source = null;
  for (let round = 0; round < 6; round++) {
    const weak = new WeakRef(box);
    box = null;
    let collected = false;
    for (let attempt = 0; attempt < 100; attempt++) {
      await new Promise(resolve => setImmediate(resolve));
      global.gc();
      if (weak.deref() === undefined) { collected = true; break; }
    }
    assert(collected, 'Dart-held containers must not retain JS wrappers');
    let rows = api.heldReferenceRows();
    box = rows[0].$1;
    assert(box instanceof api.RefBox);
    assert.equal(box, rows[0].peers[0]);
    assert.equal(box.value, 81 + round);
    box.value++;
    rows[0].peers.length = 0;
    rows = null;
    await new Promise(resolve => setImmediate(resolve));
    global.gc();
    assert.equal(api.heldReferenceRows()[0].peers[0], box);
  }
  api.holdReferenceRows(null);
  assert.equal(box.value, 87);
  assert.equal(api.referenceConstructions(), before + 1);
  const weak = new WeakRef(box);
  box = null;
  for (let attempt = 0; attempt < 100; attempt++) {
    await new Promise(resolve => setImmediate(resolve));
    global.gc();
    api.referencePressure(attempt);
    if (weak.deref() === undefined && !api.referenceAlive()) return;
  }
  assert.fail('released structural containers and their reference leaves must be collectable');
}
