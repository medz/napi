import assert from 'node:assert/strict';

export function verifyArguments(api) {
  const {
  argumentCalls, requiredNullable, optionalNumber, optionalNullable,
  optionalNull, optionalValues, optionalText, optionalDouble, optionalNaN,
  optionalInfinity, optionalNegativeInfinity, optionalWide, optionalBigInt,
  namedValues, requiredNamed, namedWide, manyNamed, optionalFailure,
  } = api;
  assert.equal(argumentCalls(), 0, 'import never invokes business main or exports');

  function rejectsBeforeCall(call, errorType = TypeError) {
    const before = argumentCalls();
    assert.throws(call, error => error instanceof errorType &&
      !(error instanceof WebAssembly.Exception));
    assert.equal(argumentCalls(), before, 'invalid inputs never enter Dart business code');
  }

  assert.equal(optionalNumber(), 7, 'private constant expression supplies the default');
  assert.equal(optionalNumber(undefined), 7);
  assert.equal(optionalNumber(0), 0);
  assert.equal(optionalNumber(-1), -1);
  assert.equal(optionalNumber(undefined, 'ignored'), 7);
  assert.equal(optionalNumber(3, 'ignored'), 3);
  assert.equal(Reflect.apply(optionalNumber, null, []), 7);
  assert.equal(Reflect.apply(optionalNumber, null, [undefined]), 7);
  rejectsBeforeCall(() => new optionalNumber());
  rejectsBeforeCall(() => optionalNumber(null));
  rejectsBeforeCall(() => optionalNumber('7'));
  rejectsBeforeCall(() => optionalNumber(1.5), RangeError);

  assert.equal(requiredNullable(null), null);
  assert.equal(requiredNullable(0), 0);
  rejectsBeforeCall(() => requiredNullable());
  rejectsBeforeCall(() => requiredNullable(undefined));
  assert.equal(optionalNullable(), 11);
  assert.equal(optionalNullable(undefined), 11);
  assert.equal(optionalNullable(null), null);
  assert.equal(optionalNullable(0), 0);
  assert.equal(optionalNull(), null);
  assert.equal(optionalNull(undefined), null);
  assert.equal(optionalNull(null), null);
  assert.equal(optionalNull(0), 0);

  assert.equal(optionalValues(), 'true|7|fallback');
  assert.equal(optionalValues(undefined, undefined, undefined), 'true|7|fallback');
  assert.equal(optionalValues(undefined, 0, ''), 'true|0|');
  assert.equal(optionalValues(false, undefined, ''), 'false|7|');
  assert.equal(optionalValues(false, 0, ''), 'false|0|');
  assert.equal(Reflect.apply(optionalValues, null, [, 0, '']), 'true|0|');
  rejectsBeforeCall(() => optionalValues(false, 0, null));
  rejectsBeforeCall(() => optionalValues(false, '0', ''));
  rejectsBeforeCall(() => optionalValues(0, 0, ''));

  const defaultText = 'a\ud800b\udfffc$\0\u2028\u2029';
  assert.equal(optionalText(), defaultText, 'evaluated string defaults preserve exact UTF-16');
  assert.equal(optionalText(undefined), defaultText);
  assert.equal(optionalText(''), '');
  assert(Object.is(optionalDouble(), -0));
  assert(Object.is(optionalDouble(undefined), -0));
  for (const value of [0, -0, 1.25, NaN, Infinity, -Infinity]) {
    assert(Object.is(optionalDouble(value), value));
  }
  assert(Number.isNaN(optionalNaN()));
  assert(Number.isNaN(optionalNaN(undefined)));
  assert.equal(optionalInfinity(), Infinity);
  assert.equal(optionalInfinity(undefined), Infinity);
  assert.equal(optionalNegativeInfinity(), -Infinity);
  assert.equal(optionalNegativeInfinity(undefined), -Infinity);

  const wide = 9007199254740993n;
  assert.equal(optionalWide(), wide);
  assert.equal(optionalWide(undefined), wide);
  assert.equal(optionalWide(0n), 0n);
  assert.equal(optionalWide(-(1n << 63n)), -(1n << 63n));
  assert.equal(optionalWide((1n << 63n) - 1n), (1n << 63n) - 1n);
  rejectsBeforeCall(() => optionalWide(0));
  rejectsBeforeCall(() => optionalWide(null));
  rejectsBeforeCall(() => optionalWide(1n << 63n), RangeError);
  assert.equal(optionalBigInt(), null);
  assert.equal(optionalBigInt(undefined), null);
  assert.equal(optionalBigInt(null), null);
  assert.equal(optionalBigInt(1n << 300n), 1n << 300n);
  rejectsBeforeCall(() => optionalBigInt(0));

  assert.equal(namedValues(3), '3|7|true|fallback|11');
  assert.equal(namedValues(3, undefined), '3|7|true|fallback|11');
  assert.equal(namedValues(3, {}), '3|7|true|fallback|11');
  assert.equal(namedValues(3, {count: undefined, flag: undefined, label: undefined, maybe: undefined}),
    '3|7|true|fallback|11');
  assert.equal(namedValues(0, {count: 0, flag: false, label: '', maybe: null}), '0|0|false||null');
  assert.equal(namedValues(0, {maybe: 0}), '0|7|true|fallback|0');
  assert.equal(namedValues(3, {}, 'ignored'), '3|7|true|fallback|11');
  assert.equal(namedValues(3, Object.create(null)), '3|7|true|fallback|11');
  assert.equal(namedValues(3, Object.assign(Object.create(null), {count: 0})), '3|0|true|fallback|11');
  assert.equal(namedValues(3, Object.defineProperty({}, 'count', {value: 0})), '3|0|true|fallback|11');
  rejectsBeforeCall(() => namedValues());
  rejectsBeforeCall(() => namedValues(undefined, {}));
  rejectsBeforeCall(() => namedValues(3, {count: null}));
  rejectsBeforeCall(() => namedValues(3, {count: 1.5}), RangeError);
  rejectsBeforeCall(() => namedValues(3, {flag: 0}));
  rejectsBeforeCall(() => namedValues(3, {label: false}));
  rejectsBeforeCall(() => namedValues(3, {unknown: undefined}));
  rejectsBeforeCall(() => namedValues(3, {[Symbol('extra')]: 1}));
  rejectsBeforeCall(() => namedValues(3, Object.defineProperty({}, 'unknown', {value: 1})));
  rejectsBeforeCall(() => namedValues(3, JSON.parse('{"__proto__":{}}')));
  for (const value of [null, false, 0, '', [], () => {}, new Date(0), Object.create({count: 1})]) {
    rejectsBeforeCall(() => namedValues(3, value));
  }
  assert.equal(namedValues(3, new Proxy({count: 0}, {})), '3|0|true|fallback|11');
  rejectsBeforeCall(() => namedValues(3, new Proxy([], {})));
  rejectsBeforeCall(() => namedValues(3, new Proxy({}, {getPrototypeOf() { return {}; }})));
  const revokedOptions = Proxy.revocable({}, {});
  revokedOptions.revoke();
  rejectsBeforeCall(() => namedValues(3, revokedOptions.proxy));
  const reflectionError = new Error('options reflection');
  for (const traps of [
    {getPrototypeOf() { throw reflectionError; }},
    {ownKeys() { throw reflectionError; }},
    {getOwnPropertyDescriptor() { throw reflectionError; }},
  ]) {
    const before = argumentCalls();
    assert.throws(() => namedValues(3, new Proxy({count: 0}, traps)), error => error === reflectionError);
    assert.equal(argumentCalls(), before);
  }

  let getterCalls = 0;
  for (const property of ['count', 'unknown']) {
    const getter = Object.defineProperty({}, property, {
      get() { getterCalls++; throw Error('getter must never run'); },
      enumerable: true,
    });
    rejectsBeforeCall(() => namedValues(3, getter));
  }
  rejectsBeforeCall(() => namedValues(3, Object.defineProperty({}, 'count', {
    set(_) { getterCalls++; },
  })));
  assert.equal(getterCalls, 0, 'options accessors are rejected without invocation');

  Object.defineProperty(Object.prototype, 'count', {
    get() { getterCalls++; throw Error('inherited getter must never run'); },
    configurable: true,
  });
  Object.defineProperty(Object.prototype, 'value', {value: 23, configurable: true});
  try {
    assert.equal(namedValues(3, {}), '3|7|true|fallback|11', 'inherited options are omitted');
    rejectsBeforeCall(() => requiredNamed(3, {}));
    assert.equal(getterCalls, 0);
  } finally {
    delete Object.prototype.count;
    delete Object.prototype.value;
  }

  assert.equal(requiredNamed(3, {value: null}), null);
  assert.equal(requiredNamed(3, {value: 0}), 0);
  assert.equal(requiredNamed(3, {value: null, flag: false}), 3);
  assert.equal(requiredNamed(3, {value: 0, flag: undefined}), 0);
  assert.equal(requiredNamed(3, Object.assign(Object.create(null), {value: null})), null);
  rejectsBeforeCall(() => requiredNamed(3));
  rejectsBeforeCall(() => requiredNamed(3, undefined));
  rejectsBeforeCall(() => requiredNamed(3, {}));
  rejectsBeforeCall(() => requiredNamed(3, {value: undefined}));
  assert.equal(namedWide(), wide);
  assert.equal(namedWide(undefined), wide);
  assert.equal(namedWide({value: undefined}), wide);
  assert.equal(namedWide({value: 0n}), 0n);
  assert.equal(namedWide({flag: false}), 0n);
  rejectsBeforeCall(() => namedWide({value: 0}));

  assert.equal(manyNamed(), 630, 'defaults are independent of any 32-bit presence mask');
  assert.equal(manyNamed({p00: 0, p31: 0, p32: undefined, p34: 0}), 562);
  assert.equal(manyNamed({p31: 1, p32: 2, p34: 4}), 537);
  rejectsBeforeCall(() => manyNamed({p34: null}));

  const beforeFailure = argumentCalls();
  assert.throws(() => optionalFailure(true), error => error instanceof Error &&
    !(error instanceof WebAssembly.Exception) && error.message.includes('optional failure'));
  assert.equal(argumentCalls(), beforeFailure + 1, 'Dart errors happen after business entry');
  assert.equal(optionalFailure(), 1);
  assert.equal(optionalNumber(), 7, 'rejected calls do not poison later valid calls');
}
