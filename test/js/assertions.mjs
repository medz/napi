// Kept independent of Node so the browser exercises the same public contract.
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
  function throws(callback, message, contains, errorType = Error) {
    let error;
    try { callback(); } catch (caught) { error = caught; }
    check(error instanceof errorType, `${message}: expected ${errorType.name}`);
    if (contains) check(error.message.includes(contains), `${message}: error omitted original message`);
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
    throws(() => api[name](undefined), `${name} does not silently treat undefined as null`);
  }

  for (const value of [0, 1, 'false', null, undefined]) throws(() => api.identityBool(value), 'invalid bool rejected');
  for (const value of [0.5, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1, Number.MIN_SAFE_INTEGER - 1, 1n, '1', null]) {
    throws(() => api.identityInt(value), 'invalid integer rejected');
  }
  for (const value of ['1', true, null, undefined]) throws(() => api.identityDouble(value), 'invalid double rejected');
  for (const value of [1, true, null, undefined]) throws(() => api.identityString(value), 'invalid string rejected');
  for (const value of [[1, 2], new Uint16Array([1, 2]), new Uint8ClampedArray([1, 2]), new DataView(new ArrayBuffer(2)), null, undefined]) {
    throws(() => api.identityBytes(value), 'invalid bytes rejected');
  }
  throws(() => api.identityInt(), 'missing argument rejected');
  throws(() => api.identityInt(1, 2), 'extra argument rejected');
  throws(() => api.oversizedInt(), 'unsafe integer result rejected');
  throws(() => api.throwError('original Dart error 🦀'), 'Dart exception translated', 'original Dart error 🦀');
  throws(() => api.identityInt(0.5), 'integer fractions use TypeError', null, TypeError);
  throws(() => api.identityInt(Number.MAX_SAFE_INTEGER + 1), 'integer overflow uses RangeError', null, RangeError);
  throws(() => api.oversizedInt(), 'integer result overflow uses RangeError', null, RangeError);
  throws(() => api.throwRange(), 'Dart RangeError translated', 'range failure', RangeError);
  throws(() => api.throwArgument(), 'Dart ArgumentError translated', 'argument failure', TypeError);
  equal(api.identityInt(42), 42, 'calls recover after errors');
  equal(api.readFile('name'), 'Dart readFile: name', 'readFile cannot collide with loader imports');
  equal(api.response('body'), 'Dart response: body', 'response cannot collide with loader local names');
  equal(api.instantiate(9), 10, 'instantiate cannot collide with runtime imports');
  equal(api.$napiReadFile('name'), 'Dart dollar: name', 'dollar function names remain usable');

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
  equal(api.identityString('after repeated errors'), 'after repeated errors', 'scope cleanup after repeated errors');
  return checks;
}
