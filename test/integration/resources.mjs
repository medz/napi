import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {cpSync, mkdtempSync} from 'node:fs';
import {basename, dirname, join} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
import {Worker, isMainThread, parentPort, workerData} from 'node:worker_threads';

const packageName = '@napi/resources-fixture';
const filename = fileURLToPath(import.meta.url);
const turn = () => new Promise(resolve => setImmediate(resolve));

function promise(call) {
  let value;
  assert.doesNotThrow(() => { value = call(); }, 'cleanup and Future calls reject asynchronously');
  assert(value instanceof Promise, 'cleanup and Future calls return genuine Promises');
  return value;
}

async function rejects(call, check = Error) {
  await assert.rejects(promise(call), check);
}

async function until(check, description) {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (check()) return;
    await turn();
  }
  assert.fail(description);
}

async function basic(api) {
  const ordinary = new api.OrdinaryCounter(3);
  assert.equal(ordinary.use(), 4);
  assert.equal('dispose' in ordinary, false);
  assert.equal('release' in ordinary, false);
  assert.equal('close' in ordinary, false);
  assert.throws(() => api.resourceConflict(), TypeError, 'incompatible resource views cannot expose one raw identity');
  assert.equal(api.resourceConflictCleanups(), 0);
  const resource = new api.ResourceCounter(1, 5);
  assert(resource instanceof api.ResourceCounter);
  assert.equal(api.resourceView(resource), resource);
  assert.equal(api.resourceIdentity(resource), resource);
  assert.equal('close' in resource, false, 'the original Dart cleanup name is renamed');
  assert.equal(resource.use(), 6);
  assert.throws(() => Reflect.construct(resource.release, []), TypeError);
  await rejects(() => Reflect.apply(resource.release, {}, []), TypeError);
  await rejects(() => resource.release(null), TypeError);
  await rejects(() => resource.release(1.5), RangeError);
  for (const exact of [new Error('cleanup-structural-reflection'), null, undefined]) {
    await rejects(() => resource.release(7, resource, new Proxy([1], {
      getOwnPropertyDescriptor() { throw exact; },
    })), error => error === exact);
  }
  assert.equal(api.resourceCleanupCalls(1), 0, 'invalid cleanup does not close the resource');
  assert.equal(resource.use(), 7);
  const closed = promise(() => resource.release(undefined, resource));
  assert.equal(promise(() => resource.release(99, resource)), closed);
  const invalidRepeat = promise(() => resource.release('bad'));
  assert.notEqual(invalidRepeat, closed, 'invalid repetition has its own rejection');
  await assert.rejects(invalidRepeat, TypeError);
  for (const exact of [new Error('repeat-structural-reflection'), null, undefined]) {
    await rejects(() => resource.release(7, resource, new Proxy([1], {
      getOwnPropertyDescriptor() { throw exact; },
    })), error => error === exact);
  }
  assert.equal(await closed, undefined, 'synchronous Dart cleanup exposes Promise<void>');
  assert.equal(resource.release(100), closed, 'terminal cleanup preserves Promise identity');
  assert.equal(api.resourceCleanupCalls(1), 1);
  assert.equal(api.resourceCleanupCode(1), 7, 'the first accepted default wins');
  assert.throws(() => resource.use());
  assert.throws(() => resource.value);
  assert.throws(() => { resource.value = 20; });
  await rejects(() => resource.hold(1));
  assert.throws(() => api.resourceUseView(resource));
  assert.throws(() => Reflect.apply(api.ResourceView.prototype.use, resource, []));
  assert.equal(api.resourceUses(), 2, 'closed-resource guards run before business code');

  const required = new api.ResourceRequired(2);
  for (const args of [[], [{}], [{code: undefined}], [null], [{code: 1, extra: 2}]]) {
    await rejects(() => required.close(...args), TypeError);
  }
  assert.equal(required.read(), 2);
  const requiredClosed = promise(() => required.close({code: null}));
  assert.equal(required.close({code: 8}), requiredClosed);
  await requiredClosed;
  assert.equal(api.resourceCleanupCode(2), 13);

  const asyncResource = new api.ResourceAsync(3);
  for (const exact of [new Error('cleanup-reflection'), null, undefined]) {
    await rejects(() => asyncResource.close(new Proxy({}, {
      getPrototypeOf() { throw exact; },
    })), error => error === exact);
  }
  let getterCalls = 0;
  await rejects(() => asyncResource.close({get code() { getterCalls++; return 5; }}), TypeError);
  assert.equal(getterCalls, 0);
  assert.equal(asyncResource.read(), 3);
  const options = {code: 17, milliseconds: 10};
  const asyncClosed = promise(() => asyncResource.close(options));
  options.code = 80;
  assert.equal(asyncResource.close({code: 19}), asyncClosed);
  await rejects(() => asyncResource.close({code: 'bad'}), TypeError);
  assert.throws(() => asyncResource.read());
  assert.equal(await asyncClosed, undefined);
  assert.equal(api.resourceCleanupCode(3), 17);
  assert.equal(api.resourceCleanupCalls(3), 1);
  assert(api.resourceEvents().includes('done:3'));
}

async function leases(api) {
  const resource = new api.ResourceCounter(10, 3);
  const operations = [
    promise(() => resource.hold(10)),
    promise(() => api.resourceHold(resource, 11)),
    promise(() => api.resourceHoldList([resource, null, resource], 12)),
    promise(() => api.resourceHoldMap(new Map([['a', resource], ['b', resource]]), 13)),
    promise(() => api.resourceHoldDictionary({a: resource, b: resource, empty: null}, 14)),
    promise(() => api.resourceHoldRecord({$1: resource, other: resource}, 15)),
    promise(() => api.resourceHoldEnvelope({owner: resource, peers: [resource, null]}, 16)),
  ];
  const closing = promise(() => resource.release(23, resource));
  assert.equal(resource.release(99, resource), closing);
  let closed = false;
  closing.then(() => { closed = true; });
  assert.equal(api.resourceCleanupCalls(10), 0);
  assert.throws(() => resource.use());
  await rejects(() => resource.hold(90));
  await rejects(() => api.resourceHold(resource, 90));
  await rejects(() => api.resourceHoldList([resource], 90));
  await rejects(() => api.resourceHoldEnvelope({owner: resource}, 90));
  for (let index = 0; index < operations.length; index++) {
    assert.equal(api.resourceCleanupCalls(10), 0, 'all accepted operations retain a lease');
    api.resourceComplete(10 + index, index);
    assert.equal(await operations[index], index);
    if (index + 1 < operations.length) {
      await turn();
      assert.equal(closed, false);
    }
  }
  await closing;
  assert.equal(api.resourceCleanupCalls(10), 1, 'duplicate nested aliases do not strand leases');
  assert.equal(api.resourceCleanupCode(10), 23);

  const snapshot = new api.ResourceCounter(17);
  const active = promise(() => snapshot.hold(17));
  const codes = [31];
  const captured = promise(() => snapshot.release(7, snapshot, codes));
  codes[0] = 99;
  assert.equal(snapshot.release(8, snapshot, [45]), captured);
  await rejects(() => snapshot.release(9, snapshot, ['bad']), TypeError);
  api.resourceComplete(17);
  await active;
  await captured;
  assert.equal(api.resourceCleanupCode(17), 31, 'deferred cleanup uses the first accepted structural snapshot');
}

async function valueResourceDefaults(api) {
  const initial = api.resourceDefaultEcho({});
  const owner = initial.owner, peer = initial.peers[0];
  assert.equal(owner.id, 300); assert.equal(peer.id, 301);
  assert.equal(initial.peers[1], null);
  assert.equal(initial.mapping.get('one'), peer);
  assert.equal(initial.labels.one, peer); assert.equal(initial.labels.empty, null);
  assert.equal(initial.pair.$1, peer); assert.equal(initial.pair.other, null);
  assert.equal(initial.marker, 7);
  const defaults = api.resourceDefaultEcho({
    owner: undefined, peers: undefined, mapping: undefined,
    labels: undefined, pair: undefined, marker: undefined,
  });
  assert.equal(defaults.owner, owner); assert.equal(defaults.peers[0], peer);
  assert.equal(defaults.mapping.get('one'), peer); assert.equal(defaults.labels.one, peer);
  assert.equal(defaults.pair.$1, peer); assert.equal(defaults.marker, 7);
  assert.equal(api.resourceDefaultEcho({owner: null}).owner, null);
  assert.throws(() => api.resourceDefaultEcho({peers: null}), TypeError);

  let ownerClosing, peerClosing;
  const input = new Proxy({marker: 7}, {
    getOwnPropertyDescriptor(target, key) {
      if (key === 'marker' && !ownerClosing) {
        ownerClosing = promise(() => owner.close());
        assert.equal(api.resourceCleanupCalls(300), 0, 'the default owner is retained before a later field is reflected');
      }
      return Reflect.getOwnPropertyDescriptor(target, key);
    },
  });
  const pending = promise(() => api.resourceDefaultHold(input, () => {
    peerClosing = promise(() => peer.close());
    assert.equal(api.resourceCleanupCalls(301), 0, 'container defaults are retained before a later callback runs');
  }, 340));
  assert(ownerClosing instanceof Promise); assert(peerClosing instanceof Promise);
  await turn();
  assert.equal(api.resourceCleanupCalls(300), 0);
  assert.equal(api.resourceCleanupCalls(301), 0);
  api.resourceComplete(340, 19);
  assert.equal(await pending, 19);
  await Promise.all([ownerClosing, peerClosing]);
  assert.equal(api.resourceCleanupCalls(300), 1);
  assert.equal(api.resourceCleanupCalls(301), 1, 'repeated default aliases release one operation lease');
  const before = api.resourceEvents();
  assert.throws(() => api.resourceDefaultEcho({}));
  assert.throws(() => api.resourceDefaultEcho({owner: null}), 'closed container defaults fail independently of the owner default');
  await rejects(() => api.resourceDefaultHold({}, () => assert.fail('closed default reached business'), 341));
  assert.deepEqual(api.resourceEvents(), before, 'closed defaults fail before constructors and business code');

  const fresh = new api.ValueDefaultResource(302);
  const explicit = api.resourceDefaultEcho({
    owner: null, peers: [], mapping: new Map(), labels: {}, pair: {$1: fresh, other: null},
  });
  assert.equal(explicit.owner, null, 'null does not select the closed owner default');
  assert.equal(explicit.pair.$1, fresh);
  await promise(() => fresh.close());
}

async function valueResourceDefaultFailure(api) {
  const initial = api.resourceDefaultEcho({});
  const valueEvents = () => api.resourceEvents().filter(event => event.startsWith('value-default-'));
  const before = valueEvents();
  let closing;
  const input = new Proxy({marker: 'invalid'}, {
    getOwnPropertyDescriptor(target, key) {
      if (key === 'marker' && !closing) {
        closing = promise(() => initial.owner.close());
        assert.equal(api.resourceCleanupCalls(300), 0);
      }
      return Reflect.getOwnPropertyDescriptor(target, key);
    },
  });
  assert.throws(() => api.resourceDefaultEcho(input), TypeError);
  assert(closing instanceof Promise);
  assert.deepEqual(valueEvents(), before, 'invalid raw fields prevent construction');
  await closing;
  assert.equal(api.resourceCleanupCalls(300), 1, 'failed input validation releases its default lease');
  assert.throws(() => api.resourceDefaultEcho({owner: null, marker: -1}), /resource-default-constructor-error/);
  assert.deepEqual(valueEvents().slice(before.length), ['value-default-constructor']);
  await promise(() => initial.peers[0].close());
  assert.equal(api.resourceCleanupCalls(301), 1, 'constructor failures release container default leases');
}

async function actualDefaultGraphs(api) {
  const owner = api.resourceGraphOwner(600);
  let closing;
  const later = new Proxy([1], {
    getOwnPropertyDescriptor(target, key) {
      if (key === '0' && !closing) {
        closing = promise(() => owner.close());
        assert.equal(api.resourceCleanupCalls(600), 0, 'private stored defaults are retained before later inputs');
      }
      return Reflect.getOwnPropertyDescriptor(target, key);
    },
  });
  const pending = promise(() => api.resourceHiddenHold(later, 620));
  assert(closing instanceof Promise);
  await turn();
  assert.equal(api.resourceCleanupCalls(600), 0);
  api.resourceComplete(620);
  assert.equal(await pending, 601);
  await closing;
  assert.equal(api.resourceCleanupCalls(600), 1);
  await rejects(() => api.resourceHiddenHold([], 621));

  const fieldOwner = api.resourceGraphOwner(601);
  let fieldClosing;
  const field = new Proxy({marker: 7}, {
    getOwnPropertyDescriptor(target, key) {
      if (key === 'marker' && !fieldClosing) {
        fieldClosing = promise(() => fieldOwner.close());
        assert.equal(api.resourceCleanupCalls(601), 0, 'lazy value defaults are retained before later fields');
      }
      return Reflect.getOwnPropertyDescriptor(target, key);
    },
  });
  const lazy = promise(() => api.resourceHiddenArray([field], 622));
  assert(fieldClosing instanceof Promise);
  await turn();
  assert.equal(api.resourceCleanupCalls(601), 0);
  api.resourceComplete(622);
  assert.equal(await lazy, 601);
  await fieldClosing;
  assert.equal(api.resourceCleanupCalls(601), 1);
  await rejects(() => api.resourceHiddenArray([{}], 623));

  await promise(() => api.resourceGraphOwner(602).close());
  assert.equal(api.resourceIgnoredDefault(), 7, 'ignored constructor arguments are outside the stored resource graph');
  assert.equal(api.resourceIgnoredDefault(undefined), 7);
}

async function genericResources(api) {
  let traps = 0;
  const hostile = new Proxy({}, {
    get() {traps++; throw Error('opaque resource payload property');},
    getPrototypeOf() {traps++; throw Error('opaque resource payload prototype');},
  });
  const payloads = [undefined, null, {stored: true}, Symbol('resource'), () => 1, hostile];
  for (const [index, payload] of payloads.entries()) {
    const resource = new api.GenericResource(410 + index, payload);
    assert.equal(resource.self(), resource);
    assert.equal(resource.value, payload);
    resource.value = undefined; assert.equal(resource.value, undefined);
    resource.value = null; assert.equal(resource.value, null);
    resource.value = payload; assert.equal(resource.value, payload);
    let observed = Symbol('not called');
    const closing = promise(() => resource.close(payload, reason => {observed = reason;}));
    assert.equal(resource.close(payload), closing);
    await closing;
    assert.equal(observed, payload);
    assert.equal(api.resourceCleanupCode(410 + index), 48, 'present opaque null and undefined are not the Dart null default');
    assert.equal(api.resourceCleanupCalls(410 + index), 1);
    assert.throws(() => resource.value);
  }
  assert.equal(traps, 0);

  const payload = {pending: true};
  const future = new api.GenericResource(420, payload);
  const pending = promise(() => future.hold(420));
  const closing = promise(() => future.close(payload));
  await turn();
  assert.equal(api.resourceCleanupCalls(420), 0);
  api.resourceComplete(420);
  assert.equal(await pending, payload);
  await closing;
  assert.equal(api.resourceCleanupCalls(420), 1);

  for (const cancel of [false, true]) {
    const id = cancel ? 422 : 421;
    const value = cancel ? null : undefined;
    const resource = new api.GenericResource(id, value);
    const iterator = resource.sequence(id);
    const first = await iterator.next();
    assert.equal(first.value, value); assert.equal(first.done, false);
    let observed = Symbol('not called');
    let closed;
    if (cancel) {
      closed = promise(() => resource.close(value, reason => {observed = reason;}));
      assert.equal(api.resourceCleanupCalls(id), 0);
      const cancelled = iterator.return();
      api.resourceComplete(id);
      assert.equal((await cancelled).done, true);
    } else {
      api.resourceComplete(id);
      const second = await iterator.next();
      assert.equal(second.value, value); assert.equal(second.done, false);
      assert.equal((await iterator.next()).done, true);
      closed = promise(() => resource.close(value, reason => {observed = reason;}));
    }
    await closed;
    assert.equal(observed, value);
    assert.equal(api.resourceCleanupCalls(id), 1);
  }

  const callbackResource = new api.GenericResource(423, payload);
  let finish, callbackClosing, observed = Symbol('not called');
  const callbackResult = promise(() => callbackResource.apply(value => {
    assert.equal(value, payload);
    callbackClosing = promise(() => callbackResource.close(undefined, reason => {observed = reason;}));
    return new Promise(resolve => {finish = () => resolve(value);});
  }));
  await turn();
  assert.equal(api.resourceCleanupCalls(423), 0, 'a pending callback keeps its generic resource operation');
  finish();
  assert.equal(await callbackResult, payload);
  await callbackClosing;
  assert.equal(observed, undefined);
  assert.equal(api.resourceCleanupCalls(423), 1);

  const invalid = new api.GenericResource(424, payload);
  await rejects(() => invalid.apply(3), TypeError);
  await promise(() => invalid.close());
  assert.equal(api.resourceCleanupCode(424), 47, 'omitting an opaque cleanup parameter keeps the Dart null default');
  assert.equal(api.resourceCleanupCalls(424), 1, 'failed callback conversion releases its operation');
}

async function failure(api) {
  const sync = new api.ResourceCounter(20);
  const first = promise(() => sync.release(-1));
  assert.equal(sync.release(99), first);
  await assert.rejects(first, /resource-sync-cleanup-error/);
  assert.equal(sync.release(0), first);
  assert.equal(api.resourceCleanupCalls(20), 1);
  assert.throws(() => sync.use());
  const asyncResource = new api.ResourceAsync(21);
  const failed = promise(() => asyncResource.close({fail: true, milliseconds: 5}));
  assert.equal(asyncResource.close(), failed);
  await assert.rejects(failed, /resource-async-cleanup-error/);
  assert.equal(asyncResource.close({fail: false}), failed);
  assert.equal(api.resourceCleanupCalls(21), 1);
  assert.throws(() => asyncResource.read());

  const conversion = new api.ResourceCounter(22);
  const bad = promise(() => api.resourceBadResult(conversion));
  const closed = promise(() => conversion.release());
  await assert.rejects(bad, RangeError);
  await closed;
  assert.equal(api.resourceCleanupCalls(22), 1, 'failed result conversion releases its operation');
}

async function dynamicCleanup(api) {
  const success = api.resourceAsyncView(140);
  const failed = api.resourceAsyncView(141, {fail: true});
  const complete = promise(() => success.close());
  const rejected = promise(() => failed.close());
  const checked = assert.rejects(rejected, /resource-override-cleanup-error/);
  assert.equal(success.close(), complete);
  assert.equal(failed.close(), rejected);
  await complete;
  assert(api.resourceEvents().includes('done:140'), 'a void-declared cleanup preserves the actual async override');
  await checked;
  assert(api.resourceEvents().includes('done:141'));
  assert.equal(api.resourceCleanupCalls(140), 1);
  assert.equal(api.resourceCleanupCalls(141), 1);
  assert.equal(failed.close(), rejected, 'async override failure is terminal');
}

async function nested(api) {
  const shapes = [
    (a, b, token) => api.resourceHoldList([a, b], token),
    (a, b, token) => api.resourceHoldMap(new Map([['a', a], ['b', b]]), token),
    (a, b, token) => api.resourceHoldDictionary({a, b}, token),
    (a, b, token) => api.resourceHoldRecord({$1: a, other: b}, token),
    (a, b, token) => api.resourceHoldEnvelope({owner: a, peers: [b]}, token),
  ];
  for (let index = 0; index < shapes.length; index++) {
    const id = 100 + index * 2;
    const first = new api.ResourceCounter(id);
    const second = new api.ResourceCounter(id + 1);
    const operation = promise(() => shapes[index](first, second, id));
    const closingFirst = promise(() => first.release());
    const closingSecond = promise(() => second.release());
    await turn();
    assert.equal(api.resourceCleanupCalls(id), 0);
    assert.equal(api.resourceCleanupCalls(id + 1), 0, 'every nested resource holds a lease');
    api.resourceComplete(id);
    await operation;
    await Promise.all([closingFirst, closingSecond]);
    const fresh = new api.ResourceCounter(id + 100);
    await rejects(() => shapes[index](fresh, second, id + 100));
    await promise(() => fresh.release());
    assert.equal(api.resourceCleanupCalls(id + 100), 1, 'failed nested admission releases earlier leases');
  }
  const dependency = new api.ResourceCounter(120);
  const owner = new api.ResourceAsync(121);
  const cleanup = promise(() => owner.close({dependency, milliseconds: 30}));
  const dependencyCleanup = promise(() => dependency.release());
  assert.equal(api.resourceCleanupCalls(120), 0, 'cleanup parameters retain different resource controls');
  await cleanup;
  await dependencyCleanup;
  assert.equal(api.resourceCleanupCalls(120), 1);
  const events = api.resourceEvents();
  assert(events.indexOf('done:121') < events.indexOf('close:120:7'));
}

async function inputReentry(api) {
  const resource = new api.ResourceCounter(130);
  let closing;
  let trapped = false;
  const input = new Proxy([resource, resource], {
    getOwnPropertyDescriptor(target, key) {
      if (key === '1' && !trapped) {
        trapped = true;
        closing = promise(() => resource.release());
        assert.equal(api.resourceCleanupCalls(130), 0, 'the first accepted reference leaf is retained before reading the next');
      }
      return Reflect.getOwnPropertyDescriptor(target, key);
    },
  });
  const operation = promise(() => api.resourceHoldList(input, 130));
  assert.equal(trapped, true);
  assert(closing instanceof Promise);
  assert.equal(api.resourceCleanupCalls(130), 0);
  api.resourceComplete(130);
  assert.equal(await operation, 42);
  await closing;
  assert.equal(api.resourceCleanupCalls(130), 1);

  for (const asynchronous of [false, true]) {
    const id = asynchronous ? 133 : 132;
    const later = new api.ResourceCounter(id, 5);
    let directClosing;
    let reflected = false;
    const first = new Proxy([1], {
      getOwnPropertyDescriptor(target, key) {
        if (key === '0' && !reflected) {
          reflected = true;
          directClosing = promise(() => later.release());
          assert.equal(api.resourceCleanupCalls(id), 0, 'all direct references are retained before structural reflection');
        }
        return Reflect.getOwnPropertyDescriptor(target, key);
      },
    });
    if (asynchronous) {
      const accepted = promise(() => api.resourceDirectOrderFuture(first, later, id));
      assert.equal(api.resourceCleanupCalls(id), 0);
      api.resourceComplete(id, 6);
      assert.equal(await accepted, 6);
    } else {
      assert.equal(api.resourceDirectOrder(first, later), 6);
    }
    assert.equal(reflected, true);
    await directClosing;
    assert.equal(api.resourceCleanupCalls(id), 1);
    const events = api.resourceEvents();
    assert(events.indexOf(asynchronous ? `direct-future:${id}:1` : `direct-sync:${id}`) < events.indexOf(`close:${id}:7`));
  }
}

async function receiverReentry(api) {
  const resource = new api.ResourceCounter(131, 5);
  let closing;
  let trapped = false;
  const options = new Proxy({amount: 4}, {
    getPrototypeOf(target) {
      if (!trapped) {
        trapped = true;
        closing = promise(() => resource.release());
        assert.equal(api.resourceCleanupCalls(131), 0, 'receiver admission precedes observable option reflection');
      }
      return Reflect.getPrototypeOf(target);
    },
  });
  assert.equal(resource.read(options), 9);
  assert.equal(trapped, true);
  await closing;
  const events = api.resourceEvents();
  assert(events.indexOf('read:131') < events.indexOf('close:131:7'));
  assert.equal(api.resourceCleanupCalls(131), 1);
}

async function adoption(api, rejectResult = false, getterThrows = false) {
  const resource = new api.ResourceCounter(30);
  let finish;
  let closing;
  let closeSettled = false;
  const exact = getterThrows === 'null' ? null
    : getterThrows === 'undefined' ? undefined : new Error('resource-thenable-rejection');
  Object.defineProperty(api.ResourceResult.prototype, 'then', {
    configurable: true,
    get() {
      closing = promise(() => resource.release());
      closing.then(() => { closeSettled = true; });
      assert.equal(api.resourceCleanupCalls(30), 0, 'the result getter runs inside the operation lease');
      assert.throws(() => resource.use());
      if (getterThrows) throw exact;
      return (resolve, reject) => { finish = rejectResult ? () => reject(exact) : () => resolve(37); };
    },
  });
  const result = promise(() => resource.result());
  const observed = getterThrows || rejectResult
    ? assert.rejects(result, error => error === exact)
    : result.then(value => assert.equal(value, 37));
  if (!getterThrows) {
    await until(() => finish !== undefined, 'thenable adoption must start');
    for (let round = 0; round < 4; round++) {
      global.gc();
      await turn();
      assert.equal(closeSettled, false);
      assert.equal(api.resourceCleanupCalls(30), 0, 'resolver handoff is not final thenable settlement');
    }
    finish();
  }
  await observed;
  await closing;
  assert.equal(api.resourceCleanupCalls(30), 1);
  delete api.ResourceResult.prototype.then;
}

async function opaqueAdoption(api) {
  let id = 200;
  for (const kind of ['resolve', 'reject', 'throw']) {
    for (const exact of [undefined, null, Symbol(kind)]) {
      const resource = new api.ResourceCounter(++id);
      let finish, closing, closeSettled = false;
      const payload = {get then() {
        closing = promise(() => resource.release());
        closing.then(() => { closeSettled = true; });
        assert.equal(api.resourceCleanupCalls(id), 0, 'opaque result getter retains its resource argument');
        if (kind === 'throw') throw exact;
        return (resolve, reject) => { finish = () => kind === 'resolve' ? resolve(exact) : reject(exact); };
      }};
      const result = promise(() => api.resourceOpaqueResult(resource, payload));
      const observed = kind === 'resolve'
        ? result.then(value => assert.equal(value, exact))
        : assert.rejects(result, error => error === exact);
      if (kind !== 'throw') {
        await until(() => finish !== undefined, 'opaque thenable adoption must start');
        for (let round = 0; round < 4; round++) {
          global.gc();
          api.resourcePressure(round);
          await turn();
          assert.equal(closeSettled, false);
          assert.equal(api.resourceCleanupCalls(id), 0, 'opaque thenable remains inside its accepted operation');
        }
        finish();
      }
      await observed;
      await closing;
      assert.equal(resource.release(), closing);
      assert.equal(api.resourceCleanupCalls(id), 1);
    }
  }
}

async function retention(api) {
  let resource = new api.ResourceCounter(40);
  const operation = promise(() => api.resourceHold(resource, 40));
  const closing = promise(() => resource.release());
  resource = null;
  for (let attempt = 0; attempt < 8; attempt++) {
    await turn();
    global.gc();
    api.resourcePressure(attempt);
    assert.equal(api.resourceAlive(40), true, 'pending leases retain the raw Dart object');
    assert.equal(api.resourceCleanupCalls(40), 0);
  }
  api.resourceComplete(40);
  await operation;
  await closing;
  assert.equal(api.resourceCleanupCalls(40), 1);
  for (let attempt = 0; attempt < 100; attempt++) {
    await turn();
    global.gc();
    api.resourcePressure(attempt);
    if (!api.resourceAlive(40)) return;
  }
  assert.fail('terminal operations and cleanup must release the raw resource');
}

async function noImplicitCleanup(api) {
  let resource = new api.ResourceCounter(41);
  const operation = promise(() => resource.hold(41));
  resource = null;
  for (let attempt = 0; attempt < 8; attempt++) {
    await turn();
    global.gc();
    api.resourcePressure(attempt);
    assert.equal(api.resourceAlive(41), true, 'open pending methods retain their receiver');
  }
  api.resourceComplete(41);
  await operation;
  for (let attempt = 0; attempt < 100; attempt++) {
    await turn();
    global.gc();
    api.resourcePressure(attempt);
    if (!api.resourceAlive(41)) {
      assert.equal(api.resourceCleanupCalls(41), 0, 'GC never executes business cleanup');
      return;
    }
  }
  assert.fail('an unowned open resource is collectible after its last operation');
}

async function orphan(api) {
  let resource = new api.ResourceCounter(42);
  promise(() => resource.orphan(42));
  let closed = false;
  promise(() => resource.release()).then(() => { closed = true; });
  resource = null;
  for (let attempt = 0; attempt < 12; attempt++) {
    await turn();
    global.gc();
    api.resourcePressure(attempt);
    assert.equal(api.resourceAlive(42), true, 'accepted orphan operations retain their raw resource');
    assert.equal(api.resourceCleanupCalls(42), 0, 'discarding the public Promise cannot cancel its lease');
    assert.equal(closed, false);
  }
  // No JS timers or ports remain. Unresolved operations preserve ownership,
  // but must not keep the Node event loop alive.
  process.on('exit', () => {
    assert.equal(closed, false);
    assert.equal(api.resourceCleanupCalls(42), 0);
  });
}

async function orphanCleanup(api) {
  let resource = new api.ResourceOrphan(43);
  promise(() => resource.close());
  resource = null;
  for (let attempt = 0; attempt < 12; attempt++) {
    await turn();
    global.gc();
    api.resourcePressure(attempt);
    assert.equal(api.resourceOrphanCleanupAlive(), true, 'accepted cleanup owns its receiver even with no operation lease or business Future root');
    assert.equal(api.resourceCleanupCalls(43), 1);
  }
  process.on('exit', () => assert.equal(api.resourceCleanupCalls(43), 1));
}

async function readoption(api) {
  let resource = new api.ResourceCounter(50);
  api.resourceKeep(resource);
  const weak = new WeakRef(resource);
  const closed = promise(() => resource.release());
  await closed;
  resource = null;
  for (let attempt = 0; attempt < 100; attempt++) {
    await turn();
    global.gc();
    api.resourcePressure(attempt);
    if (!weak.deref()) break;
  }
  assert.equal(weak.deref(), undefined, 'the original JS wrapper can be collected');
  const adopted = api.resourceHeldView();
  assert.equal(api.resourceHeld(), adopted);
  assert.throws(() => adopted.use());
  assert.throws(() => api.resourceUseView(adopted));
  assert.equal(adopted.release(), closed, 'replacement aliases retain the original cleanup Promise');
  assert.equal(api.resourceCleanupCalls(50), 1);
  api.resourceForget();
}

async function runWorker(hold) {
  await new Promise((resolve, reject) => {
    const worker = new Worker(new URL(import.meta.url), {workerData: {hold}});
    worker.once('error', reject);
    worker.once('exit', code => {
      try { assert.equal(code, hold ? 1 : 0); resolve(); }
      catch (error) { reject(error); }
    });
    if (hold) worker.once('message', message => {
      try { assert.equal(message, 'pending'); worker.terminate().catch(reject); }
      catch (error) { reject(error); }
    });
  });
}

async function scenario(name) {
  if (name === 'worker-only') {
    for (let round = 0; round < 2; round++) await Promise.all([runWorker(false), runWorker(true)]);
    return;
  }
  const api = await import(packageName);
  switch (name) {
    case 'basic': {
      const subpath = import.meta.resolve(packageName).endsWith('.wasm') ? 'module.wasm' : 'native';
      assert.equal(await import(`${packageName}/${subpath}`), api);
      await basic(api);
      break;
    }
    case 'leases':
      await leases(api);
      await valueResourceDefaults(api);
      await valueResourceDefaults(await import('@napi/resources-external'));
      await genericResources(api);
      await genericResources(await import('@napi/resources-external'));
      await actualDefaultGraphs(api);
      await actualDefaultGraphs(await import('@napi/resources-external'));
      break;
    case 'nested': await nested(api); break;
    case 'input-reentry': await inputReentry(api); break;
    case 'receiver-reentry': await receiverReentry(api); break;
    case 'failure':
      await failure(api);
      await valueResourceDefaultFailure(api);
      await valueResourceDefaultFailure(await import('@napi/resources-external'));
      break;
    case 'dynamic-cleanup': await dynamicCleanup(api); break;
    case 'adoption': await adoption(api); break;
    case 'adoption-reject': await adoption(api, true); break;
    case 'adoption-getter-error': await adoption(api, false, true); break;
    case 'adoption-getter-null': await adoption(api, false, 'null'); break;
    case 'adoption-getter-undefined': await adoption(api, false, 'undefined'); break;
    case 'opaque-adoption': await opaqueAdoption(api); break;
    case 'retention': await retention(api); break;
    case 'no-implicit-cleanup': await noImplicitCleanup(api); break;
    case 'orphan': await orphan(api); break;
    case 'orphan-cleanup': await orphanCleanup(api); break;
    case 'readoption': await readoption(api); break;
    case 'independent': {
      const entry = fileURLToPath(import.meta.resolve(packageName));
      const copied = mkdtempSync(join(process.cwd(), 'independent module 雪 '));
      cpSync(dirname(entry), copied, {recursive: true});
      const other = await import(pathToFileURL(join(copied, basename(entry))));
      const left = new api.ResourceCounter(60);
      const right = new other.ResourceCounter(60);
      await rejects(() => api.resourceHold(right, 60), TypeError);
      await rejects(() => Reflect.apply(left.release, right, []), TypeError);
      const closed = promise(() => left.release());
      assert.equal(right.use(), 1);
      await closed;
      assert.equal(other.resourceCleanupCalls(60), 0);
      await promise(() => right.release());
      assert.equal(other.resourceCleanupCalls(60), 1);
      break;
    }
    case 'liveness': {
      const resource = new api.ResourceAsync(70);
      let complete = false;
      promise(() => resource.close({milliseconds: 30})).then(() => { complete = true; });
      process.on('exit', () => {
        assert.equal(complete, true, 'Dart cleanup timers keep delivery alive');
        assert.equal(api.resourceCleanupCalls(70), 1);
      });
      break;
    }
    case 'pending': {
      const resource = new api.ResourceCounter(71);
      let adopted = false;
      Object.defineProperty(api.ResourceResult.prototype, 'then', {value() { adopted = true; }});
      promise(() => resource.hold(71));
      promise(() => resource.result());
      promise(() => resource.release());
      process.on('exit', () => {
        assert.equal(adopted, true, 'the passive settlement hook was active before natural exit');
        assert.equal(api.resourceCleanupCalls(71), 0, 'pending Futures and active settlement hooks do not keep Node alive or force cleanup');
      });
      break;
    }
    case 'unhandled-event': {
      const resource = new api.ResourceAsync(72);
      let rejected;
      let unhandled = 0;
      let handled = 0;
      process.on('unhandledRejection', (error, value) => {
        assert.equal(value, rejected, 'only the exact public cleanup Promise is reported');
        assert.match(error.message, /resource-async-cleanup-error/);
        unhandled++;
        setImmediate(() => value.catch(() => {}));
      });
      process.on('rejectionHandled', value => {
        assert.equal(value, rejected);
        handled++;
      });
      rejected = promise(() => resource.close({fail: true}));
      assert.equal(resource.close(), rejected);
      process.on('exit', () => { assert.equal(unhandled, 1); assert.equal(handled, 1); });
      break;
    }
    case 'unhandled-adoption': {
      const resource = new api.ResourceCounter(73);
      const exact = new Error('resource-public-adoption-error');
      let publicPromise;
      let closing;
      let observed = 0;
      let handled = 0;
      Object.defineProperty(api.ResourceResult.prototype, 'then', {value(resolve, reject) {
        closing = resource.release();
        assert.equal(api.resourceCleanupCalls(73), 0);
        reject(exact);
      }});
      process.on('unhandledRejection', (error, value) => {
        assert.equal(value, publicPromise, 'passive lifecycle observation creates no replacement Promise');
        assert.equal(error, exact);
        observed++;
        setImmediate(() => value.catch(() => {}));
      });
      process.on('rejectionHandled', value => { assert.equal(value, publicPromise); handled++; });
      process.on('exit', () => {
        assert.equal(observed, 1, 'passive lifecycle observation cannot hide public rejection');
        assert.equal(handled, 1);
        assert(closing instanceof Promise);
        assert.equal(api.resourceCleanupCalls(73), 1);
      });
      publicPromise = promise(() => resource.result());
      break;
    }
    case 'unhandled-strict':
      promise(() => new api.ResourceAsync(74).close({fail: true}));
      break;
    case 'workers-with-main':
      await Promise.all([promise(() => new api.ResourceAsync(75).close({milliseconds: 20})), runWorker(false), runWorker(true)]);
      assert.equal(api.resourceCleanupCalls(75), 1);
      break;
    default: throw Error(`Unknown resource scenario: ${name}`);
  }
}

if (!isMainThread) {
  const api = await import(packageName);
  await valueResourceDefaults(api);
  await valueResourceDefaults(await import('@napi/resources-external'));
  await genericResources(api);
  await genericResources(await import('@napi/resources-external'));
  if (workerData.hold) {
    const resource = new api.ResourceCounter(80);
    let adopted = false;
    Object.defineProperty(api.ResourceResult.prototype, 'then', {value() { adopted = true; }});
    promise(() => resource.later(60_000));
    promise(() => resource.result());
    promise(() => resource.release());
    await until(() => adopted, 'Worker must install a live final-settlement observer before termination');
    parentPort.postMessage('pending');
  } else {
    await promise(() => new api.ResourceAsync(81).close({milliseconds: 15}));
    assert.equal(api.resourceCleanupCalls(81), 1);
    await rejects(() => new api.ResourceCounter(82).release(-1), /resource-sync-cleanup-error/);
  }
} else if (process.argv[2]) {
  await scenario(process.argv[2]);
} else {
  const cases = ['basic', 'leases', 'nested', 'input-reentry', 'receiver-reentry', 'failure', 'dynamic-cleanup', 'adoption', 'adoption-reject',
    'adoption-getter-error', 'adoption-getter-null', 'adoption-getter-undefined', 'opaque-adoption',
    'retention', 'no-implicit-cleanup', 'orphan', 'orphan-cleanup', 'readoption', 'independent', 'liveness',
    'pending', 'unhandled-event', 'unhandled-adoption', 'unhandled-strict',
    'worker-only', 'workers-with-main'];
  for (const name of cases) {
    const rejectionMode = ['unhandled-event', 'unhandled-adoption'].includes(name) ? 'throw' : 'strict';
    const result = spawnSync(process.execPath, ['--expose-gc', `--unhandled-rejections=${rejectionMode}`, filename, name], {
      encoding: 'utf8', timeout: 20_000, maxBuffer: 4 * 1024 * 1024,
    });
    assert.ifError(result.error);
    assert.equal(result.signal, null, `${name}: ${result.stderr}`);
    if (name === 'unhandled-strict') {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /resource-async-cleanup-error/);
    } else {
      assert.equal(result.status, 0, `${name}: ${result.stdout}\n${result.stderr}`);
    }
    console.log(`Resource contract: ${name} passed`);
  }
  console.log(`Resource contract: ${cases.length} fresh-process scenarios passed`);
}
