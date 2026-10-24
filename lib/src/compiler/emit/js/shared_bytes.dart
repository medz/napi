/// Captured host operations shared by native and Wasm adapters. Controls own
/// their view; the weak reverse lookup permits one-call overlap-safe copies.
const sharedBytesPolicy = _nodeSharedBrands + _sharedBytesPolicy;
const browserSharedBytesPolicy = _browserSharedBrands + _sharedBytesPolicy;

const _nodeSharedBrands = r'''
import {types as $napiSharedTypes} from 'node:util';
const $napiSharedApply = Reflect.apply;
const $napiSharedU8 = Uint8Array;
const $napiSharedIsU8 = $napiSharedTypes.isUint8Array;
const $napiSharedIsAB = $napiSharedTypes.isArrayBuffer;
''';

const _browserSharedBrands = r'''
const $napiSharedApply = Reflect.apply;
const $napiSharedU8 = Uint8Array;
const $napiSharedTag = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(Uint8Array.prototype), Symbol.toStringTag).get;
const $napiSharedBrandLength = Object.getOwnPropertyDescriptor(ArrayBuffer.prototype, 'byteLength').get;
function $napiSharedIsU8(value) {
  return $napiSharedApply($napiSharedTag, value, []) === 'Uint8Array';
}
function $napiSharedIsAB(value) {
  try { $napiSharedApply($napiSharedBrandLength, value, []); return true; }
  catch { return false; }
}
''';

const _sharedBytesPolicy =
    r'''const $napiSharedProto = Object.getPrototypeOf(Uint8Array.prototype);
const $napiSharedDescriptor = Object.getOwnPropertyDescriptor;
const $napiSharedBuffer = $napiSharedDescriptor($napiSharedProto, 'buffer').get;
const $napiSharedOffset = $napiSharedDescriptor($napiSharedProto, 'byteOffset').get;
const $napiSharedLength = $napiSharedDescriptor($napiSharedProto, 'byteLength').get;
const $napiSharedValid = $napiSharedProto.at;
const $napiSharedSet = $napiSharedProto.set;
const $napiSharedInteger = Number.isSafeInteger;
const $napiSharedTypeError = TypeError;
const $napiSharedRangeError = RangeError;
const $napiSharedWeakMap = WeakMap;
const $napiSharedGet = WeakMap.prototype.get;
const $napiSharedPut = WeakMap.prototype.set;
const $napiSharedControls = new $napiSharedWeakMap();
function $napiSharedWindow(value, path = 'SharedBytes') {
  if (!$napiSharedIsU8(value)) throw new $napiSharedTypeError(path + ': expected Uint8Array');
  // Unlike metadata getters, at checks detached and out-of-bounds empty views.
  $napiSharedApply($napiSharedValid, value, [0]);
  const buffer = $napiSharedApply($napiSharedBuffer, value, []);
  if (!$napiSharedIsAB(buffer)) throw new $napiSharedTypeError(path + ': SharedArrayBuffer is unsupported');
  const offset = $napiSharedApply($napiSharedOffset, value, []);
  const length = $napiSharedApply($napiSharedLength, value, []);
  if (length > 0x7fffffff) throw new $napiSharedRangeError(path + ': byte length limit exceeded');
  return {__proto__: null, buffer, offset, length};
}
function $napiSharedRange(start, count, length) {
  if (!$napiSharedInteger(start) || !$napiSharedInteger(count) || start < 0 || count < 0 || start > length || count > length - start) {
    throw new $napiSharedRangeError('SharedBytes: invalid byte range');
  }
}
function $napiReadSharedBytes(value, nullable, path) {
  if (value === null && nullable) return null;
  $napiSharedWindow(value, path);
  return value;
}
function $napiAllocateSharedBytes(length) {
  $napiSharedRange(0, length, 0x7fffffff);
  return new $napiSharedU8(length);
}
function $napiSharedBytesControl(value, path = 'SharedBytes', admitted = false) {
  if (!admitted) $napiSharedWindow(value, path);
  const control = (op, a, b, c, d) => {
    const target = $napiSharedWindow(value);
    switch (op) {
      case 0: return target.length;
      case 1:
        $napiSharedRange(a, 1, target.length);
        return value[a];
      case 2:
        $napiSharedRange(a, 1, target.length);
        if (!$napiSharedInteger(b) || b < 0 || b > 255) throw new $napiSharedRangeError('SharedBytes: expected byte 0..255');
        value[a] = b;
        return;
      case 3: return value;
      case 4:
      case 5: {
        const end = b === null ? target.length : b;
        if (!$napiSharedInteger(a) || !$napiSharedInteger(end)) throw new $napiSharedRangeError('SharedBytes: invalid byte range');
        $napiSharedRange(a, end - a, target.length);
        const selected = new $napiSharedU8(target.buffer, target.offset + a, end - a);
        if (op === 4) return selected;
        const result = new $napiSharedU8(end - a);
        $napiSharedApply($napiSharedSet, result, [selected]);
        return result;
      }
      case 6: {
        const input = $napiSharedWindow(a);
        $napiSharedRange(b, input.length, target.length);
        $napiSharedApply($napiSharedSet, value, [new $napiSharedU8(input.buffer, input.offset, input.length), b]);
        return;
      }
      case 7: {
        const source = $napiSharedApply($napiSharedGet, $napiSharedControls, [a]);
        const input = $napiSharedWindow(source);
        if (!$napiSharedInteger(b)) throw new $napiSharedRangeError('SharedBytes: invalid byte range');
        const count = d === null ? input.length - b : d;
        $napiSharedRange(b, count, input.length);
        $napiSharedRange(c, count, target.length);
        const read = new $napiSharedU8(input.buffer, input.offset + b, count);
        const write = new $napiSharedU8(target.buffer, target.offset + c, count);
        $napiSharedApply($napiSharedSet, write, [read]);
        return;
      }
      default: throw new $napiSharedRangeError('SharedBytes: unknown private operation');
    }
  };
  $napiSharedApply($napiSharedPut, $napiSharedControls, [control, value]);
  return control;
}
''';

/// Wasm's SDK reads metadata dynamically. Only private staging/snapshot arrays
/// get pinned own data fields; live views and returned shared values never do.
const wasmSharedBytesPolicy = r'''
const $napiSharedDefine = Object.defineProperties;
const $napiSharedABLength = Object.getOwnPropertyDescriptor(ArrayBuffer.prototype, 'byteLength').get;
const $napiSharedWeakRef = WeakRef;
const $napiSharedDeref = WeakRef.prototype.deref;
const $napiSharedAdapters = new $napiSharedWeakMap();
function $napiSharedPin(value) {
  const window = $napiSharedWindow(value);
  const bufferLength = $napiSharedApply($napiSharedABLength, window.buffer, []);
  $napiSharedDefine(window.buffer, {__proto__: null,
    byteLength: {__proto__: null, value: bufferLength},
  });
  $napiSharedDefine(value, {__proto__: null,
    buffer: {__proto__: null, value: window.buffer},
    byteOffset: {__proto__: null, value: window.offset},
    byteLength: {__proto__: null, value: window.length},
    length: {__proto__: null, value: window.length},
  });
  return value;
}
export function sharedBytesCall(control, op, a, b, c, d) {
  try {
    let value = control(op, a, b, c, d);
    if (op === 5) value = $napiSharedPin(value);
    return {__proto__: null, threw: false, value};
  } catch (value) { return {__proto__: null, threw: true, value}; }
}
export function createSharedBytes(value) {
  try { return {__proto__: null, threw: false, value: $napiSharedBytesControl(value, 'SharedBytes', true)}; }
  catch (value) { return {__proto__: null, threw: true, value}; }
}
export function allocateSharedBytes(length, staging) {
  try {
    const value = $napiAllocateSharedBytes(length);
    return {__proto__: null, threw: false, value: staging ? $napiSharedPin(value) : value};
  } catch (value) { return {__proto__: null, threw: true, value}; }
}
export function sharedBytesTypeError() {
  return {__proto__: null, threw: true, value: new $napiSharedTypeError('SharedBytes: expected an adapter from this module')};
}
export function sharedBytesRaw(control) {
  return $napiSharedApply($napiSharedGet, $napiSharedControls, [control]);
}
export function sharedBytesThrew(envelope) { return envelope.threw ? 1 : 0; }
export function sharedBytesValue(envelope) { return envelope.value; }
export function findSharedBytes(value) {
  const weak = $napiSharedApply($napiSharedGet, $napiSharedAdapters, [value]);
  return weak === undefined ? null : $napiSharedApply($napiSharedDeref, weak, []) ?? null;
}
export function cacheSharedBytes(value, adapter) {
  $napiSharedApply($napiSharedPut, $napiSharedAdapters, [value, new $napiSharedWeakRef(adapter)]);
}
''';
