import assert from 'node:assert/strict';

function dictionary(entries) { return Object.assign(Object.create(null), Object.fromEntries(entries)); }
function typeAt(call, path) {
  assert.throws(call, error => error instanceof TypeError && error.message.startsWith(path + ':'));
}
const keyPath = (path, key) => path + '[' + JSON.stringify(key) + ']';

export function verifyDictionaries(api) {
  const entries = [['__proto__', 1], ['constructor', 2], ['', 3], ['雪\ud800\0"\\', 4], ['10', 5], ['2', 6]];
  const source = dictionary(entries);
  const output = api.echoDictionary(source);
  assert.equal(Object.getPrototypeOf(output), null);
  assert.notEqual(output, source);
  assert.deepEqual(output, source);
  assert.deepEqual(Object.keys(output), Object.keys(source));
  output.extra = 8; assert.equal(Object.hasOwn(source, 'extra'), false);
  assert.deepEqual(api.echoDictionary({a: 1}), dictionary([['a', 1]]));
  const hidden = Object.defineProperty({}, 'hidden', {value: 3});
  assert.deepEqual(api.echoDictionary(hidden), dictionary([['hidden', 3]]));
  const calls = api.dictionaryCalls();
  for (const bad of [new Map(), [], null, undefined, 3, Object.create({inherited: 1})]) {
    typeAt(() => api.echoDictionary(bad), 'echoDictionary.value');
  }
  typeAt(() => api.echoDictionary({[Symbol('bad')]: 1}), 'echoDictionary.value');
  let getters = 0;
  typeAt(() => api.echoDictionary({get bad() { getters++; return 1; }}), 'echoDictionary.value["bad"]');
  assert.equal(getters, 0);
  const badKey = '雪\ud800\0"\\';
  typeAt(() => api.echoDictionary({first: 1, [badKey]: 'bad'}), keyPath('echoDictionary.value', badKey));
  assert.equal(api.dictionaryCalls(), calls);

  const box = new api.RefBox(7);
  const row = {$1: 1, owner: box};
  const nested = {first: [row, null], empty: null};
  const copied = api.nestedDictionary(nested);
  assert.equal(Object.getPrototypeOf(copied), null);
  assert.notEqual(copied.first, nested.first);
  assert.notEqual(copied.first[0], row);
  assert.equal(copied.first[0].owner, box);
  assert.deepEqual(copied.first, nested.first);
  const references = {one: box, two: box, empty: null};
  assert.deepEqual(api.referenceDictionary(references), dictionary(Object.entries(references)));
  typeAt(() => api.referenceDictionary({bad: new Proxy(box, {})}), 'referenceDictionary.value["bad"]');
  typeAt(() => api.referenceDictionary({bad: new api.Once()}), 'referenceDictionary.value["bad"]');
  const user = new api.Dictionary(5);
  assert.equal(user.self(), user);
  assert.equal(api.userDictionary({one: user}).one, user);
  const wide = {one: {$1: -9223372036854775808n, $2: 1n << 100n}, two: {$1: 9223372036854775807n, $2: null}};
  assert.deepEqual(api.bigintDictionary(wide), dictionary(Object.entries(wide)));
  assert.equal(api.optionalDictionary(), null);
  assert.equal(api.optionalDictionary(undefined), null);
  assert.equal(api.optionalDictionary(null), null);
  assert.deepEqual(api.optionalDictionary(source), source);
  assert.equal(api.namedDictionary({value: null}), null);
  assert.throws(() => api.namedDictionary({}), TypeError);
  assert.throws(() => api.namedDictionary({value: undefined}), TypeError);
  const mixed = api.dictionaryAndMap({one: 1}, new Map([['one', 1]]));
  assert.equal(Object.getPrototypeOf(mixed.$1), null);
  assert(mixed.$2 instanceof Map);
  const holder = new api.DictionaryHolder(source, {initial: source});
  assert.deepEqual(holder.values, source);
  assert.notEqual(holder.values, holder.values);
  assert.deepEqual(holder.initial, source);
  assert.throws(() => { holder.initial = null; }, TypeError);
  holder.values = {changed: 9};
  assert.deepEqual(holder.replace(source), source);
  assert.deepEqual(api.DictionaryHolder.echo(source), source);
  assert.throws(() => { holder.values = {bad: 'bad'}; }, TypeError);
  assert.deepEqual(holder.values, source);

  const cycle = {}; cycle.self = cycle;
  typeAt(() => api.recursiveDictionary(cycle), 'recursiveDictionary.value["self"]');
  const large = Object.fromEntries(Array.from({length: 9999}, (_, i) => [String(i), i]));
  assert.deepEqual(api.echoDictionary(large), dictionary(Object.entries(large)));
  large.overflow = 1;
  assert.throws(() => api.echoDictionary(large), e => e instanceof RangeError && e.message.startsWith('echoDictionary.value:'));
  for (const length of [-1, 4294967296]) typeAt(() => api.customDictionary(length, 0), 'customDictionary result.length');
  for (const length of [0, 2]) typeAt(() => api.customDictionary(length, 0), 'customDictionary result');
  typeAt(() => api.customDictionary(2, 2), 'customDictionary result["a"]');
  assert.throws(() => api.customDictionary(1, 1), e => e.constructor === Error && e.message.includes('Dictionary entries failed'));
  assert.deepEqual(api.customDictionary(1, 0), dictionary([['a', 1]]));

  const trapError = Error('descriptor failure');
  const throwing = new Proxy({a: 1}, {getOwnPropertyDescriptor() { throw trapError; }});
  assert.throws(() => api.echoDictionary(throwing), error => error === trapError);
  const parent = {first: [row]};
  parent.first = new Proxy(parent.first, {
    getOwnPropertyDescriptor(target, name) {
      if (name === '0') { parent.later = []; assert.equal(api.identityReference(box), box); }
      return Reflect.getOwnPropertyDescriptor(target, name);
    },
  });
  assert.deepEqual(Object.keys(api.nestedDictionary(parent)), ['first']);
  let setters = 0;
  Object.defineProperty(Object.prototype, 'one', {configurable: true, set() { setters++; throw Error('inherited setter'); }});
  let safe;
  try { safe = api.referenceDictionary(references); }
  finally { delete Object.prototype.one; }
  assert.equal(setters, 0); assert.equal(safe.one, box);
  for (let i = 0; i < 3; i++) {
    assert.throws(() => api.failingDictionaryReference(), e => e instanceof RangeError && e.message.startsWith('failingDictionaryReference result["bad"].$2:'));
    global.gc?.(); assert(api.dictionaryReferenceChild() instanceof api.RefChild);
  }
  const exposed = api.createPartialReferenceBase();
  assert.throws(() => api.failingExistingDictionaryReference(exposed), RangeError);
  global.gc?.(); assert.equal(api.identityBase(exposed), exposed);
  assert.deepEqual(api.echoDictionary(source), source);
}

export function verifyForeignDictionaries(api, independent) {
  const foreign = new independent.RefBox(1);
  typeAt(() => api.referenceDictionary({bad: foreign}), 'referenceDictionary.value["bad"]');
  assert.equal(independent.referenceDictionary({one: foreign}).one, foreign);
}

export async function verifyDictionaryRetention(api) {
  let box = new api.RefBox(81);
  const weak = new WeakRef(box);
  let source = {one: box, two: box};
  api.holdDictionary(source);
  source.one = null; source.two = null; source = null; box = null;
  let collected = false;
  for (let i = 0; i < 100; i++) {
    await new Promise(resolve => setImmediate(resolve)); global.gc();
    if (weak.deref() === undefined) { collected = true; break; }
  }
  assert(collected, 'Dart Dictionaries must not retain JS wrappers');
  let held = api.heldDictionary();
  const wrapper = inspectHeldDictionary(held);
  held = null; api.holdDictionary(null);
  for (let i = 0; i < 100; i++) {
    await new Promise(resolve => setImmediate(resolve)); global.gc(); api.referencePressure(i);
    if (wrapper.deref() === undefined && !api.referenceAlive()) return;
  }
  assert.fail('released Dictionary reference leaves must be collectable');
}
function inspectHeldDictionary(held) {
  assert.equal(held.one, held.two); assert.equal(held.one.value, 81);
  return new WeakRef(held.one);
}
