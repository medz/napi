import 'dart:convert';

import '../../lowering/plan.dart';
import 'structural.dart';

Iterable<JsCollectionConversion> _collectionPolicies(
  Iterable<JsCollectionConversion> conversions,
) {
  final policies = <String, JsCollectionConversion>{};
  void add(JsCollectionConversion c) {
    if (policies.containsKey(c.signatureKey)) return;
    policies[c.signatureKey] = c;
    for (final child in [?c.key, c.value]) {
      if (child is JsCollectionConversion) add(child);
    }
  }

  conversions.forEach(add);
  return policies.values;
}

bool _copiedStructure(ValueConversion c) =>
    c is ListConversion ||
    c is MapConversion ||
    c is DictionaryConversion ||
    c is RecordConversion;

String jsCollectionPolicies(Iterable<JsCollectionConversion> conversions) {
  Map<String, Object?> element(ValueConversion c) => switch (c) {
    ScalarConversion() => {
      'opaque': false,
      'type': c.jsType,
      'nullable': c.nullable,
      'integer': c.kind == ScalarKind.integer,
    },
    OpaqueConversion() => {'opaque': true},
    BinaryConversion() => {
      'opaque': false,
      'binary': c.kind.index,
      'nullable': c.nullable,
    },
    SharedBytesConversion() => {
      'opaque': false,
      'sharedBytes': true,
      'nullable': c.nullable,
    },
    ReferenceConversion() => {
      'opaque': false,
      'reference': c.classId,
      'nullable': c.nullable,
    },
    JsCollectionConversion() => {
      'opaque': false,
      'collection': c.isMap ? 'map' : 'array',
      'nullable': c.nullable,
    },
    ListConversion() ||
    MapConversion() ||
    DictionaryConversion() ||
    RecordConversion() => {
      'opaque': false,
      'structure': true,
      'nullable': c.nullable,
      'read': null,
      'write': null,
    },
    _ => throw StateError('Unsupported JS collection element'),
  };
  return jsonEncode({
    for (final c in _collectionPolicies(conversions))
      c.signatureKey: {
        'map': c.isMap,
        'key': c.key == null ? null : element(c.key!),
        'value': element(c.value),
      },
  });
}

/// Copied elements use the ordinary structural boundary for each lazy access.
String jsCollectionStructurePolicies(
  Iterable<JsCollectionConversion> conversions,
) {
  final source = StringBuffer();
  var next = 0;
  for (final c in _collectionPolicies(conversions)) {
    for (final (field, child) in [('key', c.key), ('value', c.value)]) {
      if (child == null || !_copiedStructure(child)) continue;
      final structure = emitStructuralBoundary(
        child,
        prefix: '\$jcStructure${next++}',
        leafAdapter: const BoundaryLeafAdapter(bigintText: true),
      );
      source.writeln(structure.source);
      final policy = '\$jcPolicies[${jsonEncode(c.signatureKey)}].$field';
      source.writeln('$policy.read = ${structure.read};');
      source.writeln('$policy.write = ${structure.write};');
    }
  }
  return source.toString();
}

/// Operations act on the original container. Admission does not read elements.
const jsCollectionsPolicy = r'''
import {types as $jcTypes} from 'node:util';
const $jcApply = Reflect.apply, $jcGet = Reflect.get, $jcSet = Reflect.set;
const $jcArray = Array.isArray, $jcMap = $jcTypes.isMap, $jcProxy = $jcTypes.isProxy;
const $jcOwn = Object.hasOwn;
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
  if (policy.opaque) return value;
  if ($jcOwn(policy, 'structure')) return text ? policy.write(value, path, {work: 0, active: new Set(), pending: null}, 0) : value;
  if ($jcOwn(policy, 'binary')) return text ? $napiAdoptBinary(value, policy.binary, policy.nullable, path) : value;
  if ($jcOwn(policy, 'sharedBytes')) return text ? $napiReadSharedBytes(value, policy.nullable, path) : value;
  if ($jcOwn(policy, 'reference')) {
    if (!text || value === null && policy.nullable) return value;
    return writeReference(value, policy.reference, path);
  }
  if ($jcOwn(policy, 'collection')) return $jcAdmit(value, policy.collection === 'map', policy.nullable, path);
  return $jcScalar(text && value !== null && policy.type === 'bigint' ? $jcBigInt(value) : value, policy, path);
}
function $jcOutput(value, policy, path, text) {
  if (policy.opaque) return value;
  if ($jcOwn(policy, 'structure')) {
    if (value === null && !policy.nullable) throw new $jcTypeError(path + ': expected a copied structure');
    return text ? policy.read(value, path, {work: 0, active: new Set()}, 0) : value;
  }
  if ($jcOwn(policy, 'binary')) {
    if (value === null && !policy.nullable) throw new $jcTypeError(path + ': expected binary storage');
    return text ? $napiCopyBinary(value, policy.binary, policy.nullable, path, true) : value;
  }
  if ($jcOwn(policy, 'sharedBytes')) {
    if (value === null && !policy.nullable) throw new $jcTypeError(path + ': expected Uint8Array');
    return text ? $napiReadSharedBytes(value, policy.nullable, path) : value;
  }
  if ($jcOwn(policy, 'reference')) {
    if (value === null && !policy.nullable) throw new $jcTypeError(path + ': expected a Dart class reference');
    return text ? readReference(value, policy.reference, policy.nullable, path) : value;
  }
  if ($jcOwn(policy, 'collection')) return $jcAdmit(value, policy.collection === 'map', policy.nullable, path);
  value = $jcScalar(value, policy, path);
  return text && value !== null && policy.type === 'bigint' ? $jcApply($jcBigText, value, []) : value;
}
function $jcCall(source, policy, op, a, b, text = false) {
  const valuePath = policy.map ? 'JsMap value' : 'JsArray value';
  switch (op) {
    case 0: return $jcAdmit(source, policy.map, false, a);
    case 1: return policy.map ? $jcApply($jcSize, source, []) : source.length;
    case 2: {
      let value;
      if (policy.map) {
        a = $jcInput(a, policy.key, 'JsMap key', text);
        if (!$jcApply($jcHas, source, [a])) return null;
        value = $jcApply($jcRead, source, [a]);
      } else {
        a = $jcIndex(a);
        if (+a >= source.length) return null;
        value = $jcGet(source, a);
      }
      value = $jcOutput(value, policy.value, valuePath, text);
      // The private tuple separates absence from any opaque nullish payload.
      return policy.value.opaque ? [value] : value;
    }
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
      return step.done ? null : step.value;
    }
    case 9: return $jcOutput(a[b], b === 0 ? policy.key : policy.value, b === 0 ? 'JsMap key' : valuePath, text);
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
export function jsCollectionTypeError(message, range) {
  return {__proto__: null, threw: true, value: range ? new $jcRangeError(message) : new $jcTypeError(message ?? 'Expected a JS collection handle with this module and element policy')};
}
''';
