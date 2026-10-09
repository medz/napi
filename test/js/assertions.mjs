// The package and relative Wasm imports exercise the same public contract.
export function runAssertions(api) {
  let checks = 0;
  function check(condition, message) {
    checks++;
    if (!condition) throw new Error(message);
  }
  function equal(actual, expected, message) {
    check(Object.is(actual, expected), `${message}: ${String(actual)} != ${String(expected)}`);
  }
  function bytes(actual, expected, message) {
    check(actual instanceof Uint8Array, `${message}: expected Uint8Array`);
    check(actual.length === expected.length && actual.every((value, i) => value === expected[i]), message);
  }
  function throws(callback, message, contains, errorType = Error, parameter) {
    let error;
    try { callback(); } catch (caught) { error = caught; }
    check(error instanceof errorType, `${message}: expected ${errorType.name}`);
    if (contains) check(error.message.includes(contains), `${message}: error omitted original message`);
    if (parameter) {
      const context = `parameter ${parameter}:`;
      check(error.message.split(context).length - 1 === 1, `${message}: ${context} must occur exactly once`);
    }
    return error;
  }

  for (const value of [false, true]) equal(api.identityBool(value), value, 'bool roundtrip');
  for (const value of [0, 1, -1, Number.MAX_SAFE_INTEGER, Number.MIN_SAFE_INTEGER]) {
    equal(api.identityInt(value), value, 'safe integer roundtrip');
  }
  for (const value of [0, -0, 0.125, -1234.5, Number.MIN_VALUE, Number.MAX_VALUE, NaN, Infinity, -Infinity]) {
    equal(api.identityDouble(value), value, 'double roundtrip');
  }
  for (const value of ['', 'plain', '你好 🦀', 'a\0b', '\ud800', '\udc00', 'x'.repeat(65536)]) {
    equal(api.identityString(value), value, 'UTF-16 string roundtrip');
  }

  const input = new Uint8Array([0, 127, 128, 255]);
  const copied = api.identityBytes(input);
  bytes(copied, input, 'bytes roundtrip');
  check(copied !== input && copied.buffer !== input.buffer, 'byte return must own a copy');
  copied[0] = 99;
  equal(input[0], 0, 'returned bytes cannot mutate the caller');
  bytes(api.identityBytes(new Uint8Array()), [], 'empty bytes');
  bytes(api.identityBytes(new Uint8Array([9, 10, 11, 12]).subarray(1, 3)), [10, 11], 'typed array offset');
  const mutateInput = new Uint8Array([255, 4]);
  bytes(api.incrementFirst(mutateInput), [0, 4], 'Dart mutation returned');
  bytes(mutateInput, [255, 4], 'Dart receives an owned copy');

  for (const [name, value] of [
    ['nullableBool', false], ['nullableInt', 42], ['nullableDouble', 0.25],
    ['nullableString', 'value'], ['nullableBytes', input],
  ]) {
    equal(api[name](null), null, `${name} null`);
    if (value instanceof Uint8Array) bytes(api[name](value), value, name);
    else equal(api[name](value), value, name);
    throws(() => api[name](undefined), `${name} does not silently treat undefined as null`, null, TypeError, 'value');
    throws(() => api[name](), `${name} requires an explicit nullable argument`, null, TypeError, 'value');
  }

  for (const value of [0, 1, 'false', null, undefined]) {
    throws(() => api.identityBool(value), 'invalid bool rejected', null, TypeError, 'value');
  }
  for (const value of [0.5, NaN, Infinity, 1n, '1', null, undefined]) {
    throws(() => api.identityInt(value), 'invalid integer rejected', null, TypeError, 'then');
  }
  for (const value of [Number.MAX_SAFE_INTEGER + 1, Number.MIN_SAFE_INTEGER - 1]) {
    throws(() => api.identityInt(value), 'integer overflow uses RangeError', null, RangeError, 'then');
    throws(() => api.nullableInt(value), 'nullable integer overflow uses RangeError', null, RangeError, 'value');
  }
  for (const value of ['1', true, null, undefined]) {
    throws(() => api.identityDouble(value), 'invalid double rejected', null, TypeError, 'value');
  }
  for (const value of [1, true, null, undefined]) {
    throws(() => api.identityString(value), 'invalid string rejected', null, TypeError, 'value');
  }
  for (const value of [[1, 2], new Uint16Array([1, 2]), new Uint8ClampedArray([1, 2]), new DataView(new ArrayBuffer(2)), null, undefined]) {
    throws(() => api.identityBytes(value), 'invalid bytes rejected', null, TypeError, 'value');
  }
  for (const [name, parameter] of [
    ['identityBool', 'value'], ['identityInt', 'then'], ['identityDouble', 'value'],
    ['identityString', 'value'], ['identityBytes', 'value'],
  ]) {
    throws(() => api[name](), `${name} missing argument uses TypeError`, null, TypeError, parameter);
  }
  for (const name of ['identityBytes', 'nullableBytes']) {
    if (typeof structuredClone === 'function') {
      const detached = new Uint8Array([1, 2]);
      structuredClone(detached.buffer, { transfer: [detached.buffer] });
      throws(() => api[name](detached), `${name} detached input rejected`, null, TypeError, 'value');
    }
    if (typeof ArrayBuffer.prototype.resize === 'function') {
      const buffer = new ArrayBuffer(8, { maxByteLength: 16 });
      const outOfBounds = new Uint8Array(buffer, 2, 3);
      buffer.resize(1);
      throws(() => api[name](outOfBounds), `${name} out-of-bounds input rejected`, null, TypeError, 'value');
    }
  }
  for (const [args, parameter] of [
    [['1', 2], 'a'], [[1, '2'], 'b'], [['1', '2'], 'a'], [[], 'a'], [[1], 'b'],
  ]) {
    const before = api.counter();
    throws(() => api.countedAdd(...args), 'two-argument input rejected', 'Expected a number', TypeError, parameter);
    equal(api.counter(), before, 'argument failure prevents Dart business entry');
  }
  const beforeAdd = api.counter();
  equal(api.countedAdd(1, 2), 3, 'two-argument call recovers');
  equal(api.counter(), beforeAdd + 1, 'valid arguments enter Dart business once');
  equal(api.identityInt(1, 2), 1, 'native Wasm ignores extra arguments');
  const unsafeResult = throws(() => api.oversizedInt(), 'integer result overflow uses RangeError', null, RangeError);
  check(!unsafeResult.message.includes('parameter '), 'result failure must not gain argument context');
  const businessError = throws(() => api.throwError('original Dart error 🦀'), 'Dart exception translated', 'original Dart error 🦀');
  check(!businessError.message.includes('parameter '), 'business error must not gain argument context');
  throws(() => api.throwRange(), 'Dart RangeError translated', 'range failure', RangeError);
  throws(() => api.throwArgument(), 'Dart ArgumentError translated', 'argument failure', TypeError);
  equal(api.identityInt(42), 42, 'calls recover after errors');
  equal(api.readFile('name'), 'Dart readFile: name', 'readFile remains a named Wasm export');
  equal(api.response('body'), 'Dart response: body', 'response remains a named Wasm export');
  equal(api.instantiate(9), 10, 'instantiate remains a named Wasm export');
  equal(api.$napiReadFile('name'), 'Dart dollar: name', 'dollar function names remain usable');
  equal(api.fetch('body'), 'Dart fetch: body', 'fetch remains a named Wasm export');
  equal(api.URL(), 42, 'URL remains a named Wasm export');
  equal(api.Error(), 'Dart Error', 'Error remains a named Wasm export');

  const initial = api.counter();
  equal(api.incrementCounter(), undefined, 'void returns undefined');
  equal(api.counter(), initial + 1, 'Dart state survives calls');
  for (let i = 0; i < 10000; i++) {
    equal(api.identityInt(i), i, 'repeated integer call');
    if (i % 1000 === 0) {
      bytes(api.identityBytes(input), input, 'repeated bytes call');
      throws(() => api.throwError(`error-${i}`), 'repeated exception', `error-${i}`);
    }
  }
  equal(api.identityString('after repeated errors'), 'after repeated errors', 'calls recover after repeated errors');
  return checks;
}
