import assert from 'node:assert/strict';

export function verifyStructures(api) {
  // Complete Dart output snapshots precede host integer and Map-key checks.
  for (const call of [api.structuralOutputOrder, api.structuralCollisionOrder]) {
    assert.throws(() => call(true), error => error.constructor === Error &&
      error.message.includes('later output getter failed'));
    assert.equal(api.structuralOutputReads(), 1);
  }
  assert.throws(() => api.structuralOutputOrder(false), error =>
    error instanceof RangeError && error.message.startsWith('structuralOutputOrder result.$1:'));
  assert.equal(api.structuralOutputReads(), 1);
  assert.throws(() => api.structuralCollisionOrder(false), error =>
    error instanceof TypeError && error.message === 'structuralCollisionOrder result.$1[1].key: duplicate converted Map key');
  assert.equal(api.structuralOutputReads(), 1);
  const {
  structuralCalls, structuralLists, structuralSaved, structuralRecords,
  structuralNamed, structuralSingle, structuralEmpty, structuralBooleans,
  structuralDoubles, structuralStrings, structuralBigInts, structuralOptional,
  structuralUnsafeOutput, structuralLargeOutput,
  structuralDepth, structuralDeepOutput,
  structuralThrowingOutput, structuralInvalidLength,
  structuralNamedRequired, structuralNamedOptional, structuralMixed,
  } = api;
  const namedList = new api.NamedList(71);
  assert.equal(namedList.value, 71);
  assert.equal(namedList.self(), namedList);
  assert.equal(api.namedListIdentity(namedList), namedList);
  assert.throws(() => api.namedListIdentity([]), TypeError);
  function reject(operation, kind, path, message) {
    assert.throws(operation, (error) => error instanceof kind &&
      error.message.startsWith(path + ': ') && error.message.includes(message),
    `${kind.name} at ${path}: ${message}`);
  }

  assert.equal(structuralLists(null), null);
  const source = [[1, null], null, []];
  const result = structuralLists(source);
  assert.deepEqual(result, source);
  assert.notEqual(result, source);
  assert.notEqual(result[0], source[0]);
  source[0][0] = 9;
  result[0][0] = 20;
  assert.deepEqual(structuralSaved(), [[1, null], null, []]);
  const saved = structuralSaved();
  saved[0].push(100);
  assert.deepEqual(structuralSaved(), [[1, null], null, []]);

  const repeated = [4];
  const duplicated = structuralLists([repeated, repeated]);
  assert.notEqual(duplicated[0], duplicated[1]);
  duplicated[0].push(5);
  assert.deepEqual(duplicated[1], [4]);
  assert.deepEqual(structuralLists([Object.assign([], {length: 0})]), [[]]);

  const text = 'a\ud800b\udfffc\u0000\u2028\u2029';
  const item = {$1: text, values: [2, null], detail: {flag: true, ratio: -0}};
  assert.deepEqual(structuralRecords([item, null]), [item, null]);
  const recordOutput = structuralRecords([item, item]);
  assert.notEqual(recordOutput[0], recordOutput[1]);
  assert.notEqual(recordOutput[0].values, item.values);
  assert.notEqual(recordOutput[0].detail, item.detail);
  recordOutput[0].detail.flag = false;
  assert.equal(recordOutput[1].detail.flag, true);
  assert.deepEqual(structuralNamed({values: [1, null], nested: {label: text}}),
    {values: [1, null], nested: {label: text}});
  assert.equal(structuralNamed(null), null);
  assert.deepEqual(structuralSingle({$1: 7}), {$1: 7});
  assert.deepEqual(structuralEmpty({}), {});
  assert.deepEqual(structuralBooleans([true, false]), [true, false]);
  assert.deepEqual(structuralStrings([text]), [text]);
  assert.deepEqual(structuralDoubles([NaN, Infinity, -Infinity, -0]), [NaN, Infinity, -Infinity, -0]);
  const huge = 1n << 300n;
  assert.deepEqual(structuralBigInts([{wide: 9223372036854775807n, huge}]),
    [{wide: 9223372036854775807n, huge}]);
  assert.equal(structuralOptional(), null);
  assert.equal(structuralOptional(undefined), null);
  assert.equal(structuralOptional(null), null);
  assert.deepEqual(structuralOptional([null, 1]), [null, 1]);
  assert.equal(structuralNamedRequired({value: null}), null);
  assert.deepEqual(structuralNamedRequired({value: [1, null]}), [1, null]);
  assert.equal(structuralNamedOptional(), null);
  assert.equal(structuralNamedOptional({value: undefined}), null);
  assert.deepEqual(structuralNamedOptional({value: [2]}), [2]);
  assert.equal(structuralMixed(null), null);
  assert.deepEqual(structuralMixed([3], undefined), [3]);
  for (const options of [undefined, {}, {value: undefined}]) {
    reject(() => structuralNamedRequired(options), TypeError,
      'structuralNamedRequired.value', 'missing required argument');
  }
  reject(() => structuralMixed(), TypeError, 'structuralMixed.value', 'missing required argument');
  reject(() => structuralMixed(undefined, false), TypeError, 'structuralMixed.value', 'missing required argument');

  const calls = structuralCalls();
  reject(() => structuralLists([[1], [2, 'wrong']]), TypeError,
    'structuralLists.value[1][1]', 'expected a JavaScript number or null');
  assert.equal(structuralCalls(), calls, 'later-element failure must prevent business invocation');
  reject(() => structuralLists(undefined), TypeError, 'structuralLists.value', 'expected an Array');
  reject(() => structuralLists([[undefined]]), TypeError,
    'structuralLists.value[0][0]', 'expected a JavaScript number or null');
  reject(() => structuralLists([[1.5]]), RangeError,
    'structuralLists.value[0][0]', 'safe integer');
  reject(() => structuralLists([[9007199254740992]]), RangeError,
    'structuralLists.value[0][0]', 'safe integer');
  reject(() => structuralBigInts([{wide: 9223372036854775808n, huge}]), RangeError,
    'structuralBigInts.value[0].wide', 'signed 64-bit');
  reject(() => structuralBooleans([1]), TypeError, 'structuralBooleans.value[0]', 'boolean');
  reject(() => structuralStrings([new String('x')]), TypeError, 'structuralStrings.value[0]', 'string');
  reject(() => structuralDoubles(['1']), TypeError, 'structuralDoubles.value[0]', 'number');

  const sparse = new Array(2);
  sparse[0] = [1];
  reject(() => structuralLists(sparse), TypeError, 'structuralLists.value[1]', 'own data property');
  let gets = 0;
  const getterList = [];
  Object.defineProperty(getterList, '0', {get() { gets++; return [1]; }});
  reject(() => structuralLists(getterList), TypeError,
    'structuralLists.value[0]', 'own data property');
  const getterRecord = {$1: 'x', values: null};
  Object.defineProperty(getterRecord, 'detail', {get() { gets++; return null; }});
  reject(() => structuralRecords([getterRecord]), TypeError,
    'structuralRecords.value[0].detail', 'own data property');
  assert.equal(gets, 0, 'conversion must never invoke accessors');
  for (const prototype of [Array.prototype, Object.prototype]) {
    const previous = Object.getOwnPropertyDescriptor(prototype, '0');
    let setters = 0;
    let failure;
    let listOutput;
    let recordOutput;
    Object.defineProperty(prototype, '0', {
      configurable: true,
      set() { setters++; throw new Error('inherited index setter invoked'); },
    });
    try {
      listOutput = structuralLists([[1]]);
      recordOutput = structuralSingle({$1: 1});
    } catch (error) {
      failure = error;
    } finally {
      if (previous) Object.defineProperty(prototype, '0', previous);
      else delete prototype['0'];
    }
    assert.equal(setters, 0, 'structural snapshots must create own data properties');
    assert.equal(failure, undefined);
    assert.deepEqual(listOutput, [[1]]);
    assert.deepEqual(recordOutput, {$1: 1});
  }
  const inherited = Object.create({values: null});
  inherited.$1 = 'x';
  inherited.detail = null;
  reject(() => structuralRecords([inherited]), TypeError,
    'structuralRecords.value[0]', 'plain record');
  const missing = {$1: 'x', values: null};
  reject(() => structuralRecords([missing]), TypeError,
    'structuralRecords.value[0].detail', 'own data property');
  reject(() => structuralRecords([{$1: 'x', values: null, detail: null, extra: 1}]),
    TypeError, 'structuralRecords.value[0].extra', 'unknown record field');
  const extraArray = [[1]];
  extraArray.extra = 2;
  reject(() => structuralLists(extraArray), TypeError,
    'structuralLists.value.extra', 'unknown Array property');
  const symbolArray = [];
  symbolArray[Symbol('extra')] = 1;
  reject(() => structuralLists(symbolArray), TypeError,
    'structuralLists.value.Symbol(extra)', 'unknown Array property');
  const cycle = [];
  cycle.push(cycle);
  reject(() => structuralLists(cycle), TypeError,
    'structuralLists.value[0]', 'cyclic structural value');
  reject(() => structuralLists([Array(10000).fill(1)]), RangeError,
    'structuralLists.value[0]', 'work limit (10000)');
  reject(() => structuralUnsafeOutput(), RangeError,
    'structuralUnsafeOutput result[0]', 'safe integer');
  reject(() => structuralLargeOutput(), RangeError,
    'structuralLargeOutput result', 'work limit (10000)');
  let deep = 1;
  for (let i = 0; i < 65; i++) deep = [deep];
  reject(() => structuralDepth(deep), RangeError,
    'structuralDepth.value' + '[0]'.repeat(64), 'depth limit (64)');
  reject(() => structuralDeepOutput(), RangeError,
    'structuralDeepOutput result' + '[0]'.repeat(64), 'depth limit (64)');
  let allowedDepth = [];
  for (let i = 0; i < 63; i++) allowedDepth = [allowedDepth];
  assert.deepEqual(structuralDepth(allowedDepth), allowedDepth);
  assert.deepEqual(structuralLists([Array(9998).fill(1)]), [Array(9998).fill(1)]);
  assert.throws(() => structuralThrowingOutput(false), (error) =>
    error instanceof Error && error.message.includes('output length failed'));
  assert.throws(() => structuralThrowingOutput(true), (error) =>
    error instanceof Error && error.message.includes('output element failed'));
  assert.deepEqual(structuralLists([[7]]), [[7]], 'failure must not poison the next call');

  // Use JavaScript reflection semantics on both targets, including Proxy arrays.
  let lengths = 0;
  const transparent = new Proxy([[3]], {
    get(target, key, receiver) {
      if (key === 'length') lengths++;
      return Reflect.get(target, key, receiver);
    },
  });
  assert.deepEqual(structuralLists(transparent), [[3]]);
  assert.equal(lengths, 1, 'read each input Array length once');
  const revoked = Proxy.revocable([], {});
  revoked.revoke();
  assert.throws(() => structuralLists(revoked.proxy), TypeError);
  reject(() => structuralLists(new Proxy([], {getPrototypeOf() { return {}; }})),
    TypeError, 'structuralLists.value', 'plain Array');
  reject(() => structuralNamed(new Proxy({values: null, nested: null}, {
    getPrototypeOf() { return {}; },
  })), TypeError, 'structuralNamed.value', 'plain record');
  const sentinel = new Error('reflection sentinel');
  for (const traps of [
    {getPrototypeOf() { throw sentinel; }},
    {ownKeys() { throw sentinel; }},
    {getOwnPropertyDescriptor() { throw sentinel; }},
  ]) {
    assert.throws(() => structuralLists(new Proxy([[1]], traps)), error => error === sentinel);
    assert.deepEqual(structuralLists([[2]]), [[2]]);
  }
  for (const length of [undefined, null, '1', -1, 1.5, 0x100000000, NaN, Infinity, 1n, {}]) {
    const value = new Proxy([], {get(target, key) { return key === 'length' ? length : target[key]; }});
    reject(() => structuralLists(value), TypeError, 'structuralLists.value.length', 'expected an Array length');
  }
  for (const length of [-1, 0x100000000]) {
    reject(() => structuralInvalidLength(length), TypeError,
      'structuralInvalidLength result.length', 'expected an Array length');
  }

  // Descriptor inspection is interleaved with child conversion, not eager.
  const events = [];
  const first = new Proxy([1], {
    getOwnPropertyDescriptor(target, key) {
      events.push('inner:' + key);
      return Reflect.getOwnPropertyDescriptor(target, key);
    },
  });
  const ordered = new Proxy([first, [2]], {
    getOwnPropertyDescriptor(target, key) {
      events.push('outer:' + key);
      return Reflect.getOwnPropertyDescriptor(target, key);
    },
  });
  assert.deepEqual(structuralLists(ordered), [[1], [2]]);
  assert(events.indexOf('outer:0') < events.indexOf('inner:0'));
  assert(events.indexOf('inner:0') < events.indexOf('outer:1'));
  const firstFailure = new Proxy([['bad'], [1]], {
    getOwnPropertyDescriptor(target, key) {
      if (key === '1') throw sentinel;
      return Reflect.getOwnPropertyDescriptor(target, key);
    },
  });
  reject(() => structuralLists(firstFailure), TypeError,
    'structuralLists.value[0][0]', 'expected a JavaScript number or null');
  const changing = new Proxy([[1], [2]], {
    getOwnPropertyDescriptor(target, key) {
      const result = Reflect.getOwnPropertyDescriptor(target, key);
      if (key === '0') target.length = 1;
      return result;
    },
  });
  reject(() => structuralLists(changing), TypeError,
    'structuralLists.value[1]', 'own data property');
  for (const key of ['bad\u0000field', 'bad\ud800field', 'bad\udfff']) {
    reject(() => structuralLists(Object.assign([], {[key]: 1})), TypeError,
      'structuralLists.value.' + key, 'unknown Array property');
  }

  // Reflection may reenter the addon while its outer Dart conversion is live.
  const reentrant = new Proxy([[4]], {
    getOwnPropertyDescriptor(target, key) {
      if (key === '0') {
        global.gc?.();
        assert.deepEqual(structuralSingle({$1: 9}), {$1: 9});
      }
      return Reflect.getOwnPropertyDescriptor(target, key);
    },
  });
  assert.deepEqual(structuralLists(reentrant), [[4]]);
  assert.deepEqual(structuralLists([[8]]), [[8]], 'reflection failures leave no conversion state');

  const isSafeInteger = Number.isSafeInteger;
  try {
    for (const replacement of [() => true, () => false]) {
      Number.isSafeInteger = replacement;
      assert.deepEqual(structuralLists([[7, null]]), [[7, null]]);
      assert.deepEqual(structuralSaved(), [[7, null]], 'nested output-only leaves keep integer validation');
      const before = structuralCalls();
      for (const value of [0.5, 2 ** 53]) {
        reject(() => structuralLists([[value]]), RangeError,
          'structuralLists.value[0][0]', 'safe integer');
        reject(() => structuralSingle({$1: value}), RangeError,
          'structuralSingle.value.$1', 'safe integer');
      }
      assert.equal(structuralCalls(), before, 'invalid nested integers never enter Dart');
      reject(() => structuralUnsafeOutput(), RangeError,
        'structuralUnsafeOutput result[0]', 'safe integer');
    }
  } finally {
    Number.isSafeInteger = isSafeInteger;
  }
}
