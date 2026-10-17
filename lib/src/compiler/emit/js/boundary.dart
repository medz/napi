import 'dart:convert';

import '../../lowering/plan.dart';
import 'arguments.dart';
import 'structural.dart';

String emitBoundary(ModulePlan plan) {
  final conversions = plan.conversions;
  final policies = [
    for (final c in conversions)
      if (c is ScalarConversion) scalarPolicy(c) else null,
  ];
  final outputs = {for (final call in plan.calls) ?call.outputContext};
  final structures = {
    for (final (index, conversion) in conversions.indexed)
      if (conversion is ListConversion ||
          conversion is RecordConversion ||
          conversion is MapConversion ||
          conversion is DictionaryConversion ||
          conversion is ValueClassConversion)
        index: emitStructuralBoundary(
          conversion,
          prefix: 'structure$index',
          generateRead: !outputs.contains(index),
          generateWrite: outputs.contains(index),
        ),
  };
  return '''// Generated JS imports for the Wasm boundary, not a consumer entry.
${plan.classes.isEmpty ? '' : "import {readReference, writeReference} from './references.mjs';"}
const policies = ${jsonEncode(policies)};
function checkedScalar(value, policy, path) {
  if (value === null && policy.nullable) return null;
  if (typeof value !== policy.type) {
    throw new TypeError(path + ': expected a JavaScript ' + policy.type + (policy.nullable ? ' or null' : ''));
  }
  if (policy.integer) {
    if (policy.type === 'number' && !Number.isSafeInteger(value)) {
      throw new RangeError(path + ': expected a safe integer');
    }
    if (policy.type === 'bigint' && (value < -9223372036854775808n || value > 9223372036854775807n)) {
      throw new RangeError(path + ': expected a signed 64-bit Dart int');
    }
  }
  return value;
}
function checked(value, context) { return checkedScalar(value, policies[context], policies[context].context); }
export function readValue(value, context) {
  switch (context) {
${[for (final e in structures.entries)
    if (e.value.read != null) '    case ${e.key}: return ${e.value.read}(value, ${jsonEncode(conversions[e.key].context)}, {work: 0, active: new Set()}, 0);'].join('\n')}
    default: return checked(value, context);
  }
}
export function writeValue(value, context) {
  switch (context) {
${[for (final e in structures.entries)
    if (e.value.write != null) '    case ${e.key}: {\n      const state = {work: 0, active: new Set(), pending: null};\n      try { return ${e.value.write}(value, ${jsonEncode(conversions[e.key].context)}, state, 0); }\n      catch (error) { if (state.pending !== null) { for (const undo of state.pending) undo(); } throw error; }\n    }'].join('\n')}
    default: return checked(value, context);
  }
}
// Called only after checked() has established a primitive bigint. Decimal
// text avoids any precision-losing conversion through a JavaScript number.
export function readBigInt(value) { return value.toString(); }
export function writeBigInt(value, context) { return checked(BigInt(value), context); }
export function throwDartError(message) { throw new Error(message); }
${plan.calls.any((call) => call.returnsFuture) ? '$futurePolicy\n' : ''}${structures.isEmpty ? '' : structuralPolicy}
${conversions.any(_containsMap) ? mapStructuralPolicy : ''}
${conversions.any(containsDictionary) ? dictionaryStructuralPolicy : ''}
${structures.values.map((s) => s.source).join('\n')}
${plan.classes.isNotEmpty || plan.functions.any((f) => f.representation == ExportRepresentation.callableGlobal) ? argumentPolicy : ''}
''';
}

/// Private capabilities keep conversion and JS exception handling in JS. Their
/// raw Dart roots last through resolver handoff, including then-getter reentry.
const futurePolicy = r'''
const capturedPromise = globalThis.Promise;
export function createPromise(wrap = null) {
  let resolve, reject;
  const promise = new capturedPromise((accept, fail) => { resolve = accept; reject = fail; });
  return {promise, resolve, reject, wrap, roots: null, done: false};
}
export function retainPromise(capability, roots) { capability.roots = roots; }
function releasePromise(capability) {
  capability.roots = null;
  capability.wrap = null;
  capability.resolve = null;
  capability.reject = null;
}
export function rejectPromise(capability, error) {
  if (capability.done) return;
  capability.done = true;
  try { capability.reject(error); }
  finally { releasePromise(capability); }
}
function dartFutureError(message, stack) {
  const error = new Error(message);
  Object.defineProperty(error, 'dartStack', {value: stack, writable: true, enumerable: true, configurable: true});
  return error;
}
export function failPromise(capability, message, stack) {
  rejectPromise(capability, dartFutureError(message, stack));
}
export function throwFutureError(message, stack) {
  throw dartFutureError(message, stack);
}
export function completePromise(capability, convert) {
  if (capability.done) return;
  capability.done = true;
  try {
    const value = convert === null ? undefined : convert();
    capability.resolve(capability.wrap === null ? value : capability.wrap(value));
  } catch (error) {
    capability.reject(error);
  } finally {
    releasePromise(capability);
  }
}
''';

bool _containsMap(ValueConversion value) =>
    conversionGraph([value]).any((c) => c is MapConversion);
