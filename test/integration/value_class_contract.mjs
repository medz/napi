import assert from 'node:assert/strict';

function rejects(call, kind, path) {
  assert.throws(call, error => error instanceof kind && error.message.startsWith(path + ':'), path);
}
const point = (x, y = 7, tag = null) => ({x, y, tag});

export function verifyValueClasses(api) {
  for (const name of ['ValuePoint', 'ValueNormalized', 'ValueNode', 'ValueBranch',
    'ValueLink', 'ValueLeft', 'ValueRight', 'ValueLeaf', 'ValueSnapshot',
    'ValueGetterFailure', 'ValueKey', 'ValueEnvelope', 'ValueFailure',
    'ValueScalarOrder', 'ValueReferenceOrder']) {
    assert.equal(Object.hasOwn(api, name), false, `${name} must remain a type-only export`);
  }
  const source = {x: 2};
  const output = api.echoValuePoint(source);
  assert.deepEqual(output, point(2));
  assert.notEqual(output, source);
  assert.deepEqual(api.echoValuePoint({x: 3, y: undefined, tag: undefined}), point(3));
  assert.deepEqual(api.echoValuePoint({x: 4, y: 5, tag: 6}), point(4, 5, 6));
  assert.deepEqual(api.echoValuePoint(Object.assign(Object.create(null), {x: 5})), point(5));
  assert.equal(api.nullableValuePoint(null), null);
  rejects(() => api.nullableValuePoint(undefined), TypeError, 'nullableValuePoint.value');
  assert.deepEqual(api.normalizeValue({total: '0012'}), {total: 12, doubled: 24});
  rejects(() => api.normalizeValue({value: '12'}), TypeError, 'normalizeValue.value.value');
  rejects(() => api.normalizeValue({total: '12', doubled: 24}), TypeError, 'normalizeValue.value.doubled');
  rejects(() => api.normalizeValue({total: 12}), TypeError, 'normalizeValue.value.total');
  assert.throws(() => api.normalizeValue({total: 'wrong'}), error => error.constructor === Error);
  assert.throws(() => api.echoValuePoint({x: -1}), error => error.constructor === Error && error.message.includes('negative point'));
  assert.deepEqual(api.echoValuePoint({x: 1}), point(1));

  const before = api.valueConstructions();
  const calls = api.valueCalls();
  for (const bad of [null, undefined, [], 1, Object.create({x: 1})]) {
    rejects(() => api.echoValuePoint(bad), TypeError, 'echoValuePoint.value');
  }
  rejects(() => api.echoValuePoint({x: 1, extra: 2}), TypeError, 'echoValuePoint.value.extra');
  rejects(() => api.echoValuePoint({x: 1, [Symbol('bad')]: 2}), TypeError, 'echoValuePoint.value.Symbol(bad)');
  rejects(() => api.echoValuePoint({}), TypeError, 'echoValuePoint.value.x');
  rejects(() => api.echoValuePoint({x: undefined}), TypeError, 'echoValuePoint.value.x');
  rejects(() => api.echoValuePoint({x: 1, y: null}), TypeError, 'echoValuePoint.value.y');
  let getters = 0;
  rejects(() => api.echoValuePoint({get x() { getters++; return 1; }}), TypeError, 'echoValuePoint.value.x');
  assert.equal(getters, 0);
  rejects(() => api.valueRows([{$1: {x: -1}, $2: 1}, {$1: {x: 2}, $2: 'bad'}]), TypeError, 'valueRows.value[1].$2');
  rejects(() => api.echoValuePoints([{x: 1}, {x: 'bad'}]), TypeError, 'echoValuePoints.value[1].x');
  const hashes = api.valueHashes();
  rejects(() => api.valueKeyMap(new Map([[{id: 1}, 1], [{id: 2}, 'bad']])), TypeError, 'valueKeyMap.value[1].value');
  assert.equal(api.valueHashes(), hashes, 'raw validation must not hash materialized value keys');
  assert.equal(api.valueConstructions(), before, 'one bad raw leaf must prevent every constructor in its parameter root');
  assert.equal(api.valueCalls(), calls);
  // JS facade presence and direct-reference guards run before value materialization.
  const receiver = new api.ValueReceiver();
  const guarded = api.valueConstructions();
  for (const bad of [undefined, null, {}, new Proxy(new api.RefBox(), {})]) {
    assert.throws(() => api.valueThenReference({x: 1}, bad), TypeError);
  }
  assert.throws(() => api.valueThenReference({x: 1}), TypeError);
  assert.throws(() => receiver.pair({x: 1}), TypeError);
  assert.throws(() => receiver.pair({x: 1}, undefined), TypeError);
  assert.throws(() => receiver.named({x: 1}, {}), TypeError);
  assert.throws(() => api.ValueReceiver.checked({x: 1}, {}), TypeError);
  assert.equal(api.valueConstructions(), guarded);
  assert.equal(api.valueCalls(), calls);
  // Scalar type conversion and structural conversion still run per parameter.
  assert.throws(() => receiver.pair({x: 1}, 'bad'), TypeError);
  assert.equal(api.valueConstructions(), guarded + 1);
  assert.throws(() => api.valueThenScalar({x: 1}), TypeError);
  assert.equal(api.valueConstructions(), guarded + 2);
  assert.equal(api.valueCalls(), calls);
  assert.equal(receiver.pair({x: 2}, 3), 5);
  assert.equal(api.valueThenReference({x: 2}, new api.RefBox(3)), 5);
  const domainBefore = api.valueConstructions();
  assert.throws(() => api.echoValuePoints([{x: 1}, {x: -1}]), error => error.constructor === Error);
  assert.equal(api.valueConstructions(), domainBefore + 2, 'domain failure does not undo prior constructors');
  const map = api.valueKeyMap(new Map([[{id: 1}, 2]]));
  assert.deepEqual([...map], [[{id: 1}, 2]]);
  assert(api.valueHashes() > hashes);
  const collisionBefore = api.valueConstructions();
  rejects(() => api.valueKeyMap(new Map([[{id: 1}, 2], [{id: 1}, 3]])), TypeError, 'valueKeyMap.value[1].key');
  assert.equal(api.valueConstructions(), collisionBefore + 2, 'converted-key collisions follow materialization');

  const shared = {x: 8};
  const repeatedBefore = api.valueConstructions();
  const copies = api.echoValuePoints([shared, shared]);
  assert.equal(api.valueConstructions(), repeatedBefore + 2, 'repeated input occurrences construct independently');
  assert.notEqual(copies[0], copies[1]);
  const repeated = api.repeatedValuePoint({x: 8});
  assert.deepEqual(repeated, [point(8), point(8)]);
  assert.notEqual(repeated[0], repeated[1]);
  repeated[0].x = 10;
  assert.equal(repeated[1].x, 8);
  const node = {value: 1, next: {value: 2}};
  assert.deepEqual(api.echoValueNode(node), {value: 1, next: {value: 2, next: null}});
  assert.deepEqual(api.bigintValueNode({value: 9223372036854775807n, next: {value: -9223372036854775808n}}),
    {value: 9223372036854775807n, next: {value: -9223372036854775808n, next: null}});
  rejects(() => api.bigintValueNode({value: 1n, next: {value: 2}}), TypeError, 'bigintValueNode.value.next.value');
  rejects(() => api.echoValueNode({value: 1, next: {value: 9007199254740992}}), RangeError, 'echoValueNode.value.next.value');
  assert.deepEqual(api.echoValueBranch({label: 1, link: {text: 'next', branch: {label: 2}}}),
    {label: 1, link: {text: 'next', branch: {label: 2, link: null}}});
  const cycle = {value: 1}; cycle.next = cycle;
  rejects(() => api.echoValueNode(cycle), TypeError, 'echoValueNode.value.next');
  rejects(() => api.cyclicValueNode(), TypeError, 'cyclicValueNode result.next');
  let deep = {value: 0};
  for (let i = 0; i < 70; i++) deep = {value: i, next: deep};
  const bounded = api.valueConstructions();
  assert.throws(() => api.echoValueNode(deep), RangeError);
  assert.throws(() => api.echoValuePoints(Array.from({length: 10001}, () => ({x: 1}))), RangeError);
  assert.equal(api.valueConstructions(), bounded, 'depth and work failure must precede materialization');

  assert.deepEqual(api.echoValueLeft({left: 4}), {left: 4});
  const interfaces = api.valueInterfaces(3);
  assert.deepEqual(interfaces, {$1: {left: 3}, $2: {right: 13}});
  assert.notEqual(interfaces.$1, interfaces.$2);
  const snapshot = api.valueSnapshot();
  assert.deepEqual(snapshot, {first: {value: 9}, later: 9, repeated: {value: 9}});
  assert.notEqual(snapshot.first, snapshot.repeated);
  assert.equal(api.valueTrace(), 'first,later,repeated,leaf,leaf', 'snapshot parent getters before converting children');
  assert.throws(() => api.failingValueGetter(), error => error.constructor === Error && error.message.includes('value getter failed'));
  assert.equal(api.valueTrace(), 'first,broken', 'a failing parent getter prevents child conversion and later getters');
  // Finish the Dart output snapshot before any host scalar/brand checks.
  assert.throws(() => api.failingValueScalarOrder(), error => error.constructor === Error && error.message.includes('value getter failed'));
  assert.equal(api.valueTrace(), 'first,broken');
  const ordered = api.valueOrderReference();
  assert(ordered instanceof api.RefChild);
  assert.throws(() => api.failingValueBrandOrder(), error => error.constructor === Error && error.message.includes('value getter failed'));
  assert.equal(api.valueTrace(), 'first,broken');
  assert.equal(api.valueOrderReference(), ordered);


  const box = new api.RefBox(31);
  const envelope = {points: [{x: 1}, null], nodes: new Map([['node', {value: 2}]]),
    names: {one: {x: 3}}, row: {$1: {x: 4}, owner: box}, owner: box};
  const copied = api.echoValueEnvelope(envelope);
  assert.notEqual(copied, envelope);
  assert.deepEqual(copied.points, [point(1), null]);
  assert.deepEqual([...copied.nodes], [['node', {value: 2, next: null}]]);
  assert.equal(Object.getPrototypeOf(copied.names), null);
  assert.deepEqual(copied.names.one, point(3));
  assert.deepEqual(copied.row.$1, point(4));
  assert.equal(copied.row.owner, box); assert.equal(copied.owner, box);
  rejects(() => api.echoValueEnvelope({...envelope, owner: new Proxy(box, {})}), TypeError, 'echoValueEnvelope.value.owner');
  for (let i = 0; i < 3; i++) {
    rejects(() => api.failingValueReference(), RangeError, 'failingValueReference result.number');
    global.gc?.(); assert(api.valueReferenceChild() instanceof api.RefChild);
  }
  const exposed = api.createPartialReferenceBase();
  assert.throws(() => api.failingExistingValueReference(exposed), RangeError);
  global.gc?.(); assert.equal(api.identityBase(exposed), exposed);
  let setterCalls = 0;
  Object.defineProperty(Object.prototype, 'x', {configurable: true, set() { setterCalls++; throw Error('inherited value setter'); }});
  let safe;
  try { safe = api.echoValuePoint({x: 9}); }
  finally { delete Object.prototype.x; }
  assert.equal(setterCalls, 0);
  assert.deepEqual(safe, point(9));
}

export function verifyForeignValueClasses(api, independent) {
  const foreign = new independent.RefBox(1);
  const value = {points: [], nodes: new Map(), names: {}, row: {$1: {x: 1}, owner: null}, owner: foreign};
  rejects(() => api.echoValueEnvelope(value), TypeError, 'echoValueEnvelope.value.owner');
  assert.equal(independent.echoValueEnvelope(value).owner, foreign);
}
