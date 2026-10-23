import assert from 'node:assert/strict';

export async function hierarchy(api) {
  for (const value of [{tag: 'value'}, Symbol('payload'), () => 1, null, undefined]) {
    const child = new api.OpaqueChild(value);
    assert(child instanceof api.OpaqueBase);
    assert(child instanceof api.OpaqueChild);
    assert.equal(api.opaqueAsBase(child), child);
    assert.equal(child.self(), child);
    assert.equal(api.OpaqueBase.prototype.self.call(child), child);
    assert.equal(child.read(), value);
    assert.equal(api.OpaqueBase.prototype.read.call(child), value);
    assert.equal(child.optional(), null);
    assert.equal(child.optional(value), value);
    assert.equal(api.OpaqueBase.prototype.optional.call(child, value), value);
    assert.equal(child.choose(), null);
    assert.equal(child.choose({first: value}), value);
    assert.equal(child.choose({second: value, index: 0}), value);
    assert.equal(child.choose({first: value, index: undefined}), value);
    assert.equal(await child.later(), value);
    const iterator = child.values();
    assert.equal((await iterator.next()).value, value);
    await iterator.return();
    api.OpaqueBase.prototype.write.call(child, undefined);
    assert.equal(child.value, undefined);
    assert.throws(() => api.OpaqueBase.prototype.write.call(child), TypeError);
  }
  const first = {first: true}, second = {second: true};
  const extra = Symbol('extra');
  for (const tagged of [new api.OpaqueTagged(first, second), new api.OpaqueTaggedLeaf(first, second, extra)]) {
    assert(tagged instanceof api.OpaqueBase);
    assert(tagged instanceof api.OpaqueTagged);
    assert.equal(api.opaqueTaggedBase(tagged), tagged);
    assert.equal(tagged.self(), tagged);
    assert.equal(api.OpaqueBase.prototype.self.call(tagged), tagged);
    assert.equal(tagged.read(), first);
    assert.equal(tagged.meta, second);
    api.OpaqueBase.prototype.write.call(tagged, undefined);
    assert.equal(tagged.value, undefined);
    assert.equal(tagged.meta, second);
    tagged.meta = null;
    assert.equal(tagged.meta, null);
    tagged.meta = undefined;
    assert.equal(tagged.meta, undefined);
    if (tagged instanceof api.OpaqueTaggedLeaf) {
      assert.equal(tagged.extra, extra);
      tagged.extra = first;
      assert.equal(tagged.extra, first);
      assert.equal(tagged.meta, undefined);
    }
  }
  assert.throws(() => new api.OpaqueTagged(first), TypeError);
  assert.throws(() => new api.OpaqueTaggedLeaf(first, second), TypeError);

  const cleanups = api.opaqueResourceCleanups();
  const resource = new api.OpaqueResourceChild(first);
  assert(resource instanceof api.OpaqueResourceBase);
  assert.equal(api.opaqueAsResource(resource), resource);
  assert.equal(resource.read(), first);
  const pendingResource = api.OpaqueResourceBase.prototype.wait.call(resource);
  const closingResource = api.OpaqueResourceBase.prototype.close.call(resource);
  assert.equal(resource.close(), closingResource);
  await Promise.resolve();
  assert.equal(api.opaqueResourceCleanups(), cleanups);
  assert.throws(() => resource.read(), /closing|closed/);
  assert.throws(() => { resource.value = second; }, /closing|closed/);
  await assert.rejects(resource.wait(), /closing|closed/);
  api.opaqueComplete(74);
  assert.equal(await pendingResource, 74);
  await closingResource;
  assert.equal(api.opaqueResourceCleanups(), cleanups + 1);
  assert.throws(() => resource.read(), /closed/);

  for (const Child of [api.OpaquePairChild, api.OpaqueLeaf]) {
    const pair = new Child(first, second);
    assert(pair instanceof api.OpaquePair);
    assert.equal(pair instanceof api.OpaqueSlot, false, 'interfaces do not add a JS prototype chain');
    assert.equal(pair.first, first);
    assert.equal(pair.second, second);
    assert.equal(pair.slot, second);
    assert.equal(pair.readSecond(), second);
    assert.equal(pair.self(), pair);
    assert.equal(api.opaqueAsPair(pair), pair);
    assert.equal(api.opaqueAsSlot(pair), pair);
    Object.getOwnPropertyDescriptor(api.OpaquePair.prototype, 'first').set.call(pair, second);
    Object.getOwnPropertyDescriptor(api.OpaqueSlot.prototype, 'slot').set.call(pair, first);
    assert.equal(pair.first, second);
    assert.equal(pair.second, first);
    const values = [];
    const entries = new Map();
    assert.equal(pair.writeArray(values, first), values);
    assert.equal(values[0], first);
    assert.equal(api.OpaquePair.prototype.writeArray.call(pair, values, undefined), values);
    assert.equal(values[0], undefined);
    assert.equal(0 in values, true);
    assert.throws(() => pair.writeArray(values), TypeError);
    assert.deepEqual(values, [undefined]);
    assert.equal(pair.writeMap(entries, first, second), entries);
    assert.equal(entries.get(first), second);
    assert.equal(pair.first, first);
    assert.equal(pair.second, second);
    assert.equal(api.OpaquePair.prototype.writeMap.call(pair, entries, undefined, undefined), entries);
    assert.equal(pair.first, undefined);
    assert.equal(pair.second, undefined);
    assert.equal(entries.has(undefined), true);
    assert.equal(entries.get(undefined), undefined);
    assert.throws(() => pair.writeMap(entries, first), TypeError);
    assert.throws(() => pair.writeMap(entries), TypeError);
    assert.equal(entries.size, 2);
    assert.equal(entries.get(first), second);
    pair.slot = undefined;
    assert.equal(pair.slot, undefined);
    pair.first = null;
    assert.equal(pair.first, null);
  }
  const writeOnly = new api.OpaqueWrite();
  writeOnly.part = first;
  assert.equal(writeOnly.part, undefined);
  const readable = new api.OpaqueRead();
  assert.equal(readable.part, null);
  Object.getOwnPropertyDescriptor(api.OpaqueWrite.prototype, 'part').set.call(readable, first);
  assert.equal(readable.part, first);
  readable.part = undefined;
  assert.equal(readable.part, undefined);
  const before = api.opaqueConstructions();
  assert.throws(() => new api.OpaqueChild(), TypeError);
  assert.equal(api.opaqueConstructions(), before);
  assert.throws(() => api.opaqueBadExposure(first), /pinned before exposure/);
  const recovered = api.opaqueReadBase();
  assert(recovered instanceof api.OpaqueChild);
  assert.equal(recovered, api.opaqueReadChild());
  assert.equal(recovered.read(), first);
  assert.equal(api.opaqueConstructions(), before + 1);
  api.opaqueUnpin();

  const thenable = {then(resolve) { resolve(71); }};
  const child = new api.OpaqueChild(thenable);
  assert.equal(child.read(), thenable);
  assert.equal(await child.later(), 71);
  const iterator = child.values();
  assert.equal((await iterator.next()).value, thenable);
  await iterator.return();
  const reference = new api.OpaqueThenChild(resolve => resolve(72));
  assert.equal(await reference.later(), 72);
  for (const exact of [null, undefined]) {
    const hostile = Object.defineProperty({}, 'then', {get() { throw exact; }});
    const rejected = new api.OpaqueChild(hostile);
    await assert.rejects(rejected.later(), error => error === exact);
  }
}

export async function hierarchyRetention(api, collect, keep) {
  let pending;
  const held = (() => {
    const value = {root: true}, input = {pending: true};
    const child = new api.OpaqueChild(value);
    child.pin();
    pending = child.wait(input);
    return [new WeakRef(child), new WeakRef(value), new WeakRef(input)];
  })();
  await keep(api, () => held[1].deref() && held[2].deref(), 'inherited Future and Dart root');
  api.opaqueComplete(73);
  assert.equal(await pending, 73);
  pending = null;
  await collect(api, () => !held[0].deref() && !held[2].deref(), 'settled inherited receiver/input');
  let adopted = api.opaqueReadBase();
  assert(adopted instanceof api.OpaqueChild);
  assert.equal(adopted, api.opaqueReadChild());
  assert.equal(adopted.value, held[1].deref());
  await keep(api, () => adopted.value === held[1].deref(), 'readopted inherited payload');
  api.opaqueUnpin();
  adopted = null;
  await collect(api, () => !held[1].deref(), 'unrooted inherited payload');

  let iterator;
  const streamed = (() => {
    const value = {stream: true};
    const child = new api.OpaqueChild(value);
    iterator = child.values();
    return new WeakRef(value);
  })();
  await keep(api, () => streamed.deref(), 'inherited Stream receiver');
  assert.equal((await iterator.next()).value, streamed.deref());
  await iterator.return();
  iterator = null;
  await collect(api, () => !streamed.deref(), 'closed inherited Stream');

  let cycle;
  const cyclic = (() => {
    const payload = {};
    cycle = new api.OpaqueChild(payload);
    payload.owner = cycle;
    return [new WeakRef(payload), new WeakRef(cycle)];
  })();
  await keep(api, () => cyclic.every(ref => ref.deref()), 'rooted inherited cycle');
  api.OpaqueBase.prototype.write.call(cycle, null);
  cycle = null;
  await collect(api, () => cyclic.every(ref => !ref.deref()), 'explicitly broken inherited cycle');
}
