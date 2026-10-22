/// Hash opaque keys without coercing or inspecting application objects.
const opaqueKeyPolicy = r'''
const $napiOpaqueApply = Reflect.apply;
const $napiOpaqueGet = WeakMap.prototype.get, $napiOpaqueSet = WeakMap.prototype.set;
const $napiOpaqueIds = new WeakMap();
const $napiOpaqueChar = String.prototype.charCodeAt;
const $napiOpaqueBigIntText = BigInt.prototype.toString;
const $napiOpaqueSymbolKey = Symbol.keyFor;
const $napiOpaqueImul = Math.imul;
const $napiOpaqueBits = new DataView(new ArrayBuffer(8));
const $napiOpaqueSetFloat = DataView.prototype.setFloat64;
const $napiOpaqueGetInt = DataView.prototype.getInt32;
let $napiOpaqueNext = 0;
function $napiOpaqueTextHash(text, hash) {
  for (let i = 0; i < text.length; i++) {
    hash = $napiOpaqueImul(hash ^ $napiOpaqueApply($napiOpaqueChar, text, [i]), 16777619);
  }
  return hash | 0;
}
function $napiOpaqueHash(value) {
  if (value === null) return 1;
  switch (typeof value) {
    case 'undefined': return 2;
    case 'boolean': return value ? 3 : 4;
    case 'string': return $napiOpaqueTextHash(value, 0x811c9dc5);
    case 'bigint': return $napiOpaqueTextHash($napiOpaqueApply($napiOpaqueBigIntText, value, []), 0x9e3779b9);
    case 'number': {
      if (value === 0) return 0;
      if (value !== value) return 0x7fc00000;
      $napiOpaqueApply($napiOpaqueSetFloat, $napiOpaqueBits, [0, value]);
      let hash = $napiOpaqueApply($napiOpaqueGetInt, $napiOpaqueBits, [0]) ^ $napiOpaqueApply($napiOpaqueGetInt, $napiOpaqueBits, [4]);
      hash = $napiOpaqueImul(hash ^ (hash >>> 16), 0x7feb352d);
      hash = $napiOpaqueImul(hash ^ (hash >>> 15), 0x846ca68b);
      return (hash ^ (hash >>> 16)) | 0;
    }
    case 'symbol': {
      const key = $napiOpaqueSymbolKey(value);
      if (key !== undefined) return $napiOpaqueTextHash(key, 0x85ebca6b);
    }
  }
  let hash = $napiOpaqueApply($napiOpaqueGet, $napiOpaqueIds, [value]);
  if (hash === undefined) {
    hash = $napiOpaqueNext = ($napiOpaqueNext + 1) | 0;
    $napiOpaqueApply($napiOpaqueSet, $napiOpaqueIds, [value, hash]);
  }
  return hash;
}
''';

const wasmOpaqueKeyPolicy = r'''
export const opaqueHash = $napiOpaqueHash;
export function opaqueEquals(left, right) {
  return left === right || (left !== left && right !== right) ? 1 : 0;
}
''';
