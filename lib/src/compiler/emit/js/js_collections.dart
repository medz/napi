import 'dart:convert';

import '../../lowering/plan.dart';

String jsCollectionPolicies(Iterable<JsCollectionConversion> conversions) {
  Map<String, Object> scalar(ScalarConversion c) => {
    'type': c.jsType,
    'nullable': c.nullable,
    'integer': c.kind == ScalarKind.integer,
  };
  return jsonEncode({
    for (final c in conversions)
      c.signatureKey: {
        'map': c.isMap,
        'key': c.key == null ? null : scalar(c.key!),
        'value': scalar(c.value),
      },
  });
}

/// Operations act on the original container. Admission does not read elements.
const jsCollectionsPolicy = r'''
import {types as $jcTypes} from 'node:util';
const $jcApply = Reflect.apply, $jcGet = Reflect.get, $jcSet = Reflect.set;
const $jcArray = Array.isArray, $jcMap = $jcTypes.isMap, $jcProxy = $jcTypes.isProxy;
const $jcSize = Object.getOwnPropertyDescriptor(Map.prototype, 'size').get;
const $jcHas = Map.prototype.has, $jcRead = Map.prototype.get;
const $jcWrite = Map.prototype.set, $jcDelete = Map.prototype.delete;
const $jcClear = Map.prototype.clear, $jcEntries = Map.prototype.entries;
const $jcNext = Object.getPrototypeOf(new Map().entries()).next;
const $jcInteger = Number.isSafeInteger, $jcString = String, $jcBigInt = BigInt;
const $jcBigText = BigInt.prototype.toString;
const $jcTypeError = TypeError, $jcRangeError = RangeError;
function $jcAdmit(value, map, nullable, path) {
  if (value === null && nullable) return null;
  if ($jcProxy(value) || !(map ? $jcMap(value) : $jcArray(value))) {
    throw new $jcTypeError(path + ': expected a JavaScript ' + (map ? 'Map' : 'Array'));
  }
  return value;
}
function $jcScalar(value, policy, path) {
  if (value === null && policy.nullable) return value;
  if (typeof value !== policy.type) throw new $jcTypeError(path + ': expected ' + policy.type + (policy.nullable ? ' or null' : ''));
  if (policy.integer && (policy.type === 'number' ? !$jcInteger(value) : value < -9223372036854775808n || value > 9223372036854775807n)) {
    throw new $jcRangeError(path + ': integer out of range');
  }
  return value;
}
function $jcIndex(index) {
  if (!$jcInteger(index) || index < 0 || index > 0xfffffffe) throw new $jcRangeError('JsArray: invalid index');
  return $jcString(index);
}
// BigInt text is private Wasm transport only, never the public JS value.
function $jcInput(value, policy, path, text) {
  return $jcScalar(text && value !== null && policy.type === 'bigint' ? $jcBigInt(value) : value, policy, path);
}
function $jcOutput(value, policy, path, text) {
  value = $jcScalar(value, policy, path);
  return text && value !== null && policy.type === 'bigint' ? $jcApply($jcBigText, value, []) : value;
}
function $jcCall(source, policy, op, a, b, text = false) {
  const valuePath = policy.map ? 'JsMap value' : 'JsArray value';
  switch (op) {
    case 0: return $jcAdmit(source, policy.map, false, a);
    case 1: return policy.map ? $jcApply($jcSize, source, []) : source.length;
    case 2:
      if (policy.map) {
        a = $jcInput(a, policy.key, 'JsMap key', text);
        return $jcApply($jcHas, source, [a]) ? $jcOutput($jcApply($jcRead, source, [a]), policy.value, valuePath, text) : null;
      }
      a = $jcIndex(a);
      return +a >= source.length ? null : $jcOutput($jcGet(source, a), policy.value, valuePath, text);
    case 3:
      a = policy.map ? $jcInput(a, policy.key, 'JsMap key', text) : $jcIndex(a);
      b = $jcInput(b, policy.value, valuePath, text);
      if (policy.map) $jcApply($jcWrite, source, [a, b]);
      else if (!$jcSet(source, a, b)) throw new $jcTypeError('JsArray: assignment failed');
      return null;
    case 4: return $jcApply($jcHas, source, [$jcInput(a, policy.key, 'JsMap key', text)]);
    case 5: return $jcApply($jcDelete, source, [$jcInput(a, policy.key, 'JsMap key', text)]);
    case 6: $jcApply($jcClear, source, []); return null;
    case 7: return $jcApply($jcEntries, source, []);
    case 8: {
      const step = $jcApply($jcNext, a, []);
      if (step.done) return null;
      return [$jcOutput(step.value[0], policy.key, 'JsMap key', text), $jcOutput(step.value[1], policy.value, valuePath, text)];
    }
    default: throw new $jcTypeError('Unknown JS collection operation');
  }
}
''';

const wasmJsCollectionsPolicy = r'''
const $jcWeakMap = WeakMap, $jcWeakRef = WeakRef;
const $jcWeakGet = WeakMap.prototype.get, $jcWeakSet = WeakMap.prototype.set;
const $jcDeref = WeakRef.prototype.deref, $jcCreate = Object.create;
const $jcAdapters = new $jcWeakMap();
export function jsCollectionCall(source, signature, op, a, b) {
  try { return {__proto__: null, threw: false, value: $jcCall(source, $jcPolicies[signature], op, a, b, true)}; }
  catch (value) { return {__proto__: null, threw: true, value}; }
}
export function jsCollectionThrew(envelope) { return envelope.threw ? 1 : 0; }
export function jsCollectionValue(envelope) { return envelope.value; }
export function jsCollectionField(entry, index) { return entry[index]; }
export function jsCollectionFind(source, signature) {
  const entries = $jcApply($jcWeakGet, $jcAdapters, [source]);
  const weak = entries?.[signature];
  return weak === undefined ? null : $jcApply($jcDeref, weak, []) ?? null;
}
export function jsCollectionCache(source, signature, adapter) {
  let entries = $jcApply($jcWeakGet, $jcAdapters, [source]);
  if (entries === undefined) {
    entries = $jcCreate(null);
    $jcApply($jcWeakSet, $jcAdapters, [source, entries]);
  }
  entries[signature] = new $jcWeakRef(adapter);
}
export function jsCollectionTypeError() {
  return {__proto__: null, threw: true, value: new $jcTypeError('Expected a JS collection handle with this module and scalar policy')};
}
''';
