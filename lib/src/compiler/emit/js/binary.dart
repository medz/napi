/// Captured binary intrinsics are shared by both target boundaries. The native
/// backend copies the validated window in bulk; Wasm wraps a private snapshot.
const binaryPolicy = r'''
import {types as $napiBinaryTypes} from 'node:util';
const $napiBinaryApply = Reflect.apply;
const $napiBinaryArray = Uint8Array;
const $napiBinaryIsArray = $napiBinaryTypes.isUint8Array;
const $napiBinaryIsBuffer = $napiBinaryTypes.isArrayBuffer;
const $napiBinaryPrototype = Object.getPrototypeOf(Uint8Array.prototype);
const $napiBinaryBuffer = Object.getOwnPropertyDescriptor($napiBinaryPrototype, 'buffer').get;
const $napiBinaryOffset = Object.getOwnPropertyDescriptor($napiBinaryPrototype, 'byteOffset').get;
const $napiBinaryLength = Object.getOwnPropertyDescriptor($napiBinaryPrototype, 'byteLength').get;
const $napiBinaryBufferLength = Object.getOwnPropertyDescriptor(ArrayBuffer.prototype, 'byteLength').get;
const $napiBinaryAt = $napiBinaryPrototype.at;
const $napiBinarySet = $napiBinaryPrototype.set;
const $napiBinaryDefine = Object.defineProperties;
const $napiBinaryDelete = Reflect.deleteProperty;
const $napiBinaryInteger = Number.isSafeInteger;
const $napiBinaryTypeError = TypeError;
const $napiBinaryRangeError = RangeError;
// Kind 0 is Uint8List; kind 1 is ByteBuffer. Never inspect user properties.
function $napiBinaryView(value, kind, nullable, path) {
  if (nullable && value === null) return null;
  const expected = kind === 0 ? 'Uint8Array' : 'ArrayBuffer';
  if (!(kind === 0 ? $napiBinaryIsArray(value) : $napiBinaryIsBuffer(value))) {
    throw new $napiBinaryTypeError(path + ': expected ' + expected + (nullable ? ' or null' : ''));
  }
  const buffer = kind === 0 ? $napiBinaryApply($napiBinaryBuffer, value, []) : value;
  if (!$napiBinaryIsBuffer(buffer)) {
    throw new $napiBinaryTypeError(path + ': SharedArrayBuffer backing is not supported');
  }
  let offset, length, view;
  try {
    if (kind === 0) {
      // Metadata getters alone turn detached/out-of-bounds views into apparent
      // empty views. at() validates them without calling user code or allocating.
      $napiBinaryApply($napiBinaryAt, value, [0]);
      offset = $napiBinaryApply($napiBinaryOffset, value, []);
      length = $napiBinaryApply($napiBinaryLength, value, []);
    } else {
      offset = 0;
      length = $napiBinaryApply($napiBinaryBufferLength, buffer, []);
    }
    // An explicit length freezes a length-tracking view's admitted window.
    view = new $napiBinaryArray(buffer, offset, length);
  } catch {
    throw new $napiBinaryTypeError(path + ': detached or out-of-bounds binary storage');
  }
  if (length > 0x7fffffff) {
    throw new $napiBinaryRangeError(path + ': binary byte length exceeds 2147483647');
  }
  return view;
}
function $napiCopyBinary(value, kind, nullable, path, privateInput = false) {
  const view = $napiBinaryView(value, kind, nullable, path);
  if (view === null) return null;
  const length = $napiBinaryApply($napiBinaryLength, view, []);
  const snapshot = $napiAllocateBinary(length, privateInput);
  $napiBinaryApply($napiBinarySet, snapshot, [view]);
  const buffer = $napiBinaryApply($napiBinaryBuffer, snapshot, []);
  return kind === 0 ? snapshot : buffer;
}
function $napiAllocateBinary(length, privateInput) {
  if (!$napiBinaryInteger(length) || length < 0 || length > 0x7fffffff) {
    throw new $napiBinaryRangeError('binary byte length must be between 0 and 2147483647');
  }
  const snapshot = new $napiBinaryArray(length);
  if (privateInput) {
    const buffer = $napiBinaryApply($napiBinaryBuffer, snapshot, []);
    // The SDK reads these properties while wrapping host storage. Own immutable
    // metadata keeps the private copy independent of caller prototype getters.
    $napiBinaryDefine(snapshot, {
      __proto__: null,
      buffer: {__proto__: null, value: buffer, configurable: true},
      byteOffset: {__proto__: null, value: 0, configurable: true},
      byteLength: {__proto__: null, value: length, configurable: true},
      length: {__proto__: null, value: length, configurable: true},
    });
    $napiBinaryDefine(buffer, {__proto__: null,
      byteLength: {__proto__: null, value: length, configurable: true}});
  }
  return snapshot;
}
function $napiAdoptBinary(value, kind, nullable, path) {
  $napiBinaryView(value, kind, nullable, path);
  return value;
}
''';

/// Only generated Dart writers allocate and finish these private snapshots.
const wasmBinaryPolicy = r'''
export function allocateBinary(length) { return $napiAllocateBinary(length, true); }
export function finishBinary(value, kind) {
  const buffer = $napiBinaryApply($napiBinaryBuffer, value, []);
  $napiBinaryDelete(value, 'buffer');
  $napiBinaryDelete(value, 'byteOffset');
  $napiBinaryDelete(value, 'byteLength');
  $napiBinaryDelete(value, 'length');
  $napiBinaryDelete(buffer, 'byteLength');
  return kind === 0 ? value : buffer;
}
''';
