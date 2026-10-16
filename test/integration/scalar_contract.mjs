import assert from 'node:assert/strict';

export function verifyScalars(api) {
  const {
  add, calls, scalarCalls, echo, fail, evaluate, argumentCount,
  echoBool, negate, echoString, reverseString, stringLength, stringCodeUnitAt,
  echoDouble, reciprocal, echoBigInt, addBigInt,
  nullableBool, nullableString, nullableDouble, nullableInt, nullableBigInt,
  echoWideInt, addWideInt, nullableWideInt, chooseWideInt, promoteWideInt,
  wideIntToDouble, unsafeIntResult, unsafeNullableIntResult,
} = api;
  assert.equal(calls(), 0, 'import does not run Dart business main');
  assert.equal(scalarCalls(), 0, 'import does not invoke scalar business functions');
  assert.equal(evaluate(40), 41, 'Dart eval declaration uses a safe export alias');
  assert.equal(argumentCount(40), 42, 'Dart arguments declaration uses a safe export alias');
  assert.equal(add(2, 3), 5);
  assert.equal(calls(), 1);
  assert.equal(add.length, 2);
  assert.equal(chooseWideInt.length, 5);
  assert.throws(() => new add(1, 2), TypeError);
  assert.throws(() => new echoString('x'), TypeError);

  let coercions = 0;
  const hostile = {
    valueOf() { coercions++; throw Error('coerced'); },
    toString() { coercions++; throw Error('coerced'); },
    [Symbol.toPrimitive]() { coercions++; throw Error('coerced'); },
  };
  const hostileProxy = new Proxy({}, {
    get() { coercions++; throw Error('read an invalid input property'); },
  });
  const objects = [
    [], {}, () => {}, Object.create(null), hostile, hostileProxy,
    new Number(2), new Boolean(false), new String('x'), Object(2n),
  ];
  const primitiveValues = ['2', '', true, false, null, undefined, 2, 2n, Symbol('x')];

  function inputError(name, parameter, errorType = TypeError) {
    return error => error instanceof errorType &&
      !(error instanceof WebAssembly.Exception) &&
      error.message.includes(name) && error.message.includes(parameter);
  }
  function rejectsBeforeCall(name, fn, parameter, values, errorType = TypeError) {
    const before = scalarCalls();
    for (const value of values) {
      assert.throws(() => fn(value), inputError(name, parameter, errorType),
        `${name} rejects invalid input without coercion`);
    }
    assert.equal(scalarCalls(), before, `${name}: invalid input never enters Dart business code`);
  }

  for (const wrong of [...primitiveValues.filter(value => typeof value !== 'number'), ...objects]) {
    assert.throws(() => add(wrong, 1), inputError('add', 'a'));
    assert.throws(() => add(1, wrong), inputError('add', 'b'));
  }
  const unsafeNumbers = [NaN, Infinity, -Infinity, 1.5, Number.MAX_SAFE_INTEGER + 1, Number.MIN_SAFE_INTEGER - 1];
  for (const wrong of unsafeNumbers) {
    assert.throws(() => add(wrong, 0), inputError('add', 'a', RangeError));
    assert.throws(() => add(0, wrong), inputError('add', 'b', RangeError));
  }
  assert.throws(() => add(), inputError('add', 'a'));
  assert.throws(() => add(1), inputError('add', 'b'));
  assert.equal(calls(), 1, 'invalid int arguments never entered business code');
  for (const value of [0, 1, -1, Number.MAX_SAFE_INTEGER, Number.MIN_SAFE_INTEGER]) {
    assert.equal(echo(value), value);
  }
  assert.equal(echo(-0), 0, 'Dart int canonicalizes negative zero');

  const scalarContracts = [
    ['echoBool', echoBool, 'boolean', false],
    ['echoString', echoString, 'string', false],
    ['echoDouble', echoDouble, 'number', false],
    ['echoBigInt', echoBigInt, 'bigint', false],
    ['echoWideInt', echoWideInt, 'bigint', false],
    ['nullableBool', nullableBool, 'boolean', true],
    ['nullableString', nullableString, 'string', true],
    ['nullableDouble', nullableDouble, 'number', true],
    ['nullableInt', nullableInt, 'number', true],
    ['nullableBigInt', nullableBigInt, 'bigint', true],
    ['nullableWideInt', nullableWideInt, 'bigint', true],
  ];
  for (const [name, fn, primitive, nullable] of scalarContracts) {
    const wrong = primitiveValues.filter(value => typeof value !== primitive && !(nullable && value === null));
    rejectsBeforeCall(name, fn, 'value', [...wrong, ...objects]);
    const before = scalarCalls();
    assert.throws(() => fn(), inputError(name, 'value'), `${name}: omitted is not null`);
    assert.equal(scalarCalls(), before);
    if (nullable) assert.equal(fn(null), null, `${name}: nullable result stays null`);
  }
  rejectsBeforeCall('nullableInt', nullableInt, 'value', unsafeNumbers, RangeError);
  assert.equal(coercions, 0, 'invalid values never invoke coercion hooks or property getters');

  for (const value of [true, false]) {
    assert.equal(echoBool(value), value);
    assert.equal(negate(value), !value, 'boolean logic runs in Dart');
    assert.equal(nullableBool(value), value);
  }

  // Compare UTF-16 code units, including malformed sequences, not UTF-8 bytes.
  const strings = ['', 'plain ASCII', '中文 café', '\0a\0', 'a\r\nb', '🙂', '\ud800', '\udfff', 'x\ud800y\udfffz', '\ud800\ud800', '\udfff\udfff'];
  for (const value of strings) {
    assert.equal(echoString(value), value);
    assert.equal(nullableString(value), value);
    assert.equal(stringLength(value), value.length, 'Dart sees the original UTF-16 length');
    for (let index = 0; index < value.length; index++) {
      assert.equal(stringCodeUnitAt(value, index), value.charCodeAt(index));
    }
    assert.equal(reverseString(value), value.split('').reverse().join(''), 'Dart-produced lone surrogates survive output');
  }

  for (const value of [0, -0, 1, -1, 1.25, Number.MIN_VALUE, Number.MAX_VALUE, NaN, Infinity, -Infinity]) {
    assert(Object.is(echoDouble(value), value), 'double result preserves IEEE-754 value, including NaN and -0');
    assert(Object.is(nullableDouble(value), value), 'nullable double has the same numeric contract');
  }
  assert.equal(reciprocal(-0), -Infinity, 'Dart receives negative zero, not canonicalized int zero');
  assert.equal(reciprocal(0), Infinity);
  assert(Object.is(reciprocal(-Infinity), -0), 'negative zero produced by Dart survives output');
  for (const value of [0, -0, 1, -1, Number.MAX_SAFE_INTEGER, Number.MIN_SAFE_INTEGER]) {
    assert.equal(nullableInt(value), value === 0 ? 0 : value);
  }

  const signed64Min = -(1n << 63n);
  const signed64Max = (1n << 63n) - 1n;
  for (const value of [0n, 1n, -1n, BigInt(Number.MAX_SAFE_INTEGER), 1n << 53n, -(1n << 53n), signed64Min, signed64Max]) {
    assert.equal(echoWideInt(value), value);
    assert.equal(nullableWideInt(value), value);
    assert.equal(addWideInt(value, 0n), value);
    assert.equal(promoteWideInt(value), value);
  }
  for (const [name, fn] of [['echoWideInt', echoWideInt], ['nullableWideInt', nullableWideInt]]) {
    rejectsBeforeCall(name, fn, 'value', [signed64Min - 1n, signed64Max + 1n, 1n << 200n, -(1n << 200n)], RangeError);
  }
  rejectsBeforeCall('addWideInt', value => addWideInt(0n, value), 'right', [signed64Max + 1n], RangeError);
  rejectsBeforeCall('addWideInt', value => addWideInt(value, 0n), 'left', [signed64Min - 1n], RangeError);
  rejectsBeforeCall('chooseWideInt', value => chooseWideInt(true, 1n, value, 'pick', 1.5), 'right', [1, undefined, {}]);
  rejectsBeforeCall('chooseWideInt', value => chooseWideInt(true, 1n, 2n, 'pick', value), 'score', [1n, null, undefined]);
  assert.equal(chooseWideInt(true, signed64Max, null, 'left', 1.5), signed64Max);
  assert.equal(chooseWideInt(false, 1n, null, 'right', Infinity), null);
  assert.equal(chooseWideInt(false, null, signed64Min, 'right', -0), signed64Min);
  assert.equal(chooseWideInt(true, 1n, 2n, '', 1), null);
  assert.equal(wideIntToDouble(2n), 2, 'bigint policy does not change double results');
  assert.equal(typeof wideIntToDouble(2n), 'number');

  const huge = (1n << 521n) + (1n << 257n) + 123456789n;
  for (const value of [0n, 1n, -1n, signed64Min - 1n, signed64Max + 1n, huge, -huge]) {
    assert.equal(echoBigInt(value), value);
    assert.equal(nullableBigInt(value), value);
    assert.equal(addBigInt(value, 1n), value + 1n, 'arbitrary-precision arithmetic runs in Dart');
  }
  assert.equal(addBigInt(huge, -huge), 0n);
  rejectsBeforeCall('addBigInt', value => addBigInt(huge, value), 'right', [0, null, undefined, hostile]);

  function outputError(name) {
    return error => error instanceof RangeError &&
      !(error instanceof WebAssembly.Exception) &&
      error.message.includes(name) && /result|return|output/i.test(error.message);
  }
  assert.throws(() => add(Number.MAX_SAFE_INTEGER, 1), outputError('add'));
  assert.throws(() => add(Number.MIN_SAFE_INTEGER, -1), outputError('add'));
  for (const [name, fn] of [['unsafeIntResult', unsafeIntResult], ['unsafeNullableIntResult', unsafeNullableIntResult]]) {
    for (const negative of [false, true]) {
      const before = scalarCalls();
      assert.throws(() => fn(negative), outputError(name));
      assert.equal(scalarCalls(), before + 1, 'output rejection happens after the Dart call');
      assert.equal(echoString('still usable'), 'still usable');
    }
  }
  assert.throws(() => fail(1), e => e instanceof Error && !(e instanceof WebAssembly.Exception) && /intentional failure/.test(e.message));
  assert.throws(() => fail(2), e => e instanceof Error && !(e instanceof WebAssembly.Exception) && /description unavailable/.test(e.message));
  assert.equal(fail(0), 0);
  assert.equal(add(3, 4), 7, 'errors do not poison runtime');
  assert.equal(echoWideInt(signed64Max), signed64Max);
  assert.equal(echoBigInt(huge), huge);
  assert.equal(coercions, 0, 'errors never stringify hostile argument values');
}
