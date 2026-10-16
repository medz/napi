import assert from 'node:assert/strict';
import vm from 'node:vm';

function typeAt(call, path) {
  assert.throws(call, error => error instanceof TypeError && error.message.startsWith(path + ':'));
}

export function verifyMaps(api) {
  const source = new Map([['__proto__', 1], ['雪\ud800', 2], ['10', 3], ['2', 4]]);
  const output = api.echoMap(source);
  assert(output instanceof Map);
  assert.notEqual(output, source);
  assert.deepEqual([...output], [...source]);
  output.set('extra', 8);
  assert.equal(source.has('extra'), false);
  const calls = api.mapCalls();
  for (const bad of [{}, [], null, undefined, new Proxy(source, {})]) {
    typeAt(() => api.echoMap(bad), 'echoMap.value');
  }
  const revoked = Proxy.revocable(source, {}); revoked.revoke();
  typeAt(() => api.echoMap(revoked.proxy), 'echoMap.value');
  typeAt(() => api.echoMap(new Map([['first', 1], ['bad', '2']])), 'echoMap.value[1].value');
  typeAt(() => api.echoMap(new Map([[1, 2]])), 'echoMap.value[0].key');
  assert.equal(api.mapCalls(), calls);
  assert.deepEqual(api.echoMap(vm.runInNewContext('new Map([["realm", 3]])')), new Map([['realm', 3]]));
  class SubMap extends Map {
    get size() { throw Error('instance size'); }
    entries() { throw Error('instance entries'); }
    [Symbol.iterator]() { throw Error('instance iterator'); }
  }
  assert.deepEqual(api.echoMap(new SubMap([['subclass', 4]])), new Map([['subclass', 4]]));

  const box = new api.RefBox(7);
  const row = {$1: 1, owner: box};
  const nested = new Map([['row', [row, null]], ['null', null]]);
  const copied = api.nestedMap(nested);
  assert.notEqual(copied.get('row'), nested.get('row'));
  assert.notEqual(copied.get('row')[0], row);
  assert.equal(copied.get('row')[0].owner, box);
  assert.deepEqual(copied, nested);
  typeAt(() => api.nestedMap(new Map([['bad', [{$1: 1, owner: {}}]]])), 'nestedMap.value[0].value[0].owner');
  const references = new Map([[box, box], [null, box]]);
  assert.deepEqual(api.referenceMap(references), references);
  typeAt(() => api.referenceMap(new Map([[new Proxy(box, {}), box]])), 'referenceMap.value[0].key');
  typeAt(() => api.referenceMap(new Map([[box, new api.Once()]])), 'referenceMap.value[0].value');
  const user = new api.Map(5);
  assert.equal(user.self(), user);
  assert.equal(api.userMap(new Map([[user, user]])).get(user), user);
  typeAt(() => api.recordKeyMap(new Map([[{$1: 1}, 'a'], [{$1: 1}, 'b']])), 'recordKeyMap.value[1].key');
  assert.deepEqual([...api.recordKeyMap(new Map([[{$1: 2}, 'kept']]))], [[{$1: 2}, 'kept']]);
  const key = new api.MapKey(1);
  const equal = new api.MapKey(1);
  typeAt(() => api.equalKeyMap(new Map([[key, 1], [equal, 2]])), 'equalKeyMap.value[1].key');
  key.failHash = true;
  assert.throws(() => api.equalKeyMap(new Map([[key, 1]])), e => e.constructor === Error && e.message.includes('Map hash failed'));
  key.failHash = false;
  key.failEquals = equal.failEquals = true;
  assert.throws(() => api.equalKeyMap(new Map([[key, 1], [equal, 2]])), e => e.constructor === Error && e.message.includes('Map equality failed'));
  key.failEquals = equal.failEquals = false;
  assert.equal(api.equalKeyMap(new Map([[key, 1]])).get(key), 1);

  const doubles = new Map([[NaN, 'nan'], [-0, 'zero'], [Infinity, 'infinity']]);
  assert.deepEqual(api.doubleMap(doubles), doubles);
  assert.equal(api.mapFindsNaN(doubles), false, 'ordinary Dart equality is retained');
  typeAt(() => api.duplicateNaNMap(), 'duplicateNaNMap result[1].key');
  assert.deepEqual(api.bigintMap(new Map([[-9223372036854775808n, 1n << 100n], [9223372036854775807n, null]])),
    new Map([[-9223372036854775808n, 1n << 100n], [9223372036854775807n, null]]));
  assert.equal(api.optionalMap(), null);
  assert.equal(api.optionalMap(undefined), null);
  assert.equal(api.optionalMap(null), null);
  assert.deepEqual(api.optionalMap(source), source);
  assert.equal(api.namedMap({value: null}), null);
  assert.throws(() => api.namedMap({}), TypeError);
  assert.throws(() => api.namedMap({value: undefined}), TypeError);
  const holder = new api.MapHolder(source, {initial: source});
  assert.deepEqual(holder.values, source);
  assert.notEqual(holder.values, holder.values);
  assert.deepEqual(holder.initial, source);
  assert.throws(() => { holder.initial = null; }, TypeError);
  holder.values = new Map([['changed', 9]]);
  assert.deepEqual(holder.replace(source), source);
  assert.deepEqual(api.MapHolder.echo(source), source);
  assert.throws(() => { holder.values = {}; }, TypeError);
  assert.deepEqual(holder.values, source);

  const cycle = new Map(); cycle.set('self', cycle);
  typeAt(() => api.recursiveMap(cycle), 'recursiveMap.value[0].value');
  const large = new Map(Array.from({length: 4999}, (_, i) => [String(i), i]));
  assert.deepEqual(api.echoMap(large), large);
  large.set('overflow', 1);
  assert.throws(() => api.echoMap(large), e => e instanceof RangeError && e.message.startsWith('echoMap.value:'));
  for (const length of [-1, 4294967296]) typeAt(() => api.customMap(length, false), 'customMap result.length');
  for (const length of [0, 2]) typeAt(() => api.customMap(length, false), 'customMap result');
  assert.throws(() => api.customMap(1, true), e => e.constructor === Error && e.message.includes('Map entries failed'));
  assert.deepEqual(api.customMap(1, false), new Map([[1, 2]]));

  const parent = new Map();
  let changed = 0;
  parent.set('first', new Proxy([row], {
    getOwnPropertyDescriptor(target, name) {
      if (name === '0') { changed++; parent.set('later', []); assert.equal(api.identityReference(box), box); }
      return Reflect.getOwnPropertyDescriptor(target, name);
    },
  }));
  assert.deepEqual([...api.nestedMap(parent).keys()], ['first']);
  assert.equal(changed, 1);
  // Flat snapshot writes must not invoke inherited numeric setters.
  let setters = 0;
  Object.defineProperty(Array.prototype, '0', {configurable: true, set() { setters++; throw Error('inherited setter'); }});
  let safe;
  try { safe = api.referenceMap(references); }
  finally { delete Array.prototype[0]; }
  assert.equal(setters, 0); assert.deepEqual(safe, references);
  for (let i = 0; i < 3; i++) {
    typeAt(() => api.failingMapReference(), 'failingMapReference result[1].key');
    global.gc?.();
    assert(api.mapReferenceChild() instanceof api.RefChild);
  }
  const exposed = api.createPartialReferenceBase();
  typeAt(() => api.failingExistingMapReference(exposed), 'failingExistingMapReference result[1].key');
  global.gc?.();
  assert.equal(api.identityBase(exposed), exposed);
  assert.deepEqual(api.echoMap(source), source, 'errors leave the next call usable');
}

export function verifyForeignMaps(api, independent) {
  const foreign = new independent.RefBox(1);
  typeAt(() => api.referenceMap(new Map([[foreign, null]])), 'referenceMap.value[0].key');
  assert.equal(independent.referenceMap(new Map([[foreign, foreign]])).get(foreign), foreign);
}

export async function verifyMapRetention(api) {
  let box = new api.RefBox(81);
  const weak = new WeakRef(box);
  let source = new Map([[box, box]]);
  api.holdMap(source);
  source.clear(); source = null; box = null;
  let collected = false;
  for (let i = 0; i < 100; i++) {
    await new Promise(resolve => setImmediate(resolve)); global.gc();
    if (weak.deref() === undefined) { collected = true; break; }
  }
  assert(collected, 'Dart Maps must not retain JS wrappers');
  let held = api.heldMap();
  const wrapper = inspectHeldMap(held);
  held = null; api.holdMap(null);
  for (let i = 0; i < 100; i++) {
    await new Promise(resolve => setImmediate(resolve)); global.gc(); api.referencePressure(i);
    if (wrapper.deref() === undefined && !api.referenceAlive()) return;
  }
  assert.fail('released Map reference leaves must be collectable');
}

function inspectHeldMap(held) {
  const [key, value] = held.entries().next().value;
  assert.equal(key, value); assert.equal(key.value, 81);
  return new WeakRef(key);
}
