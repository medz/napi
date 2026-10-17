import 'dart:convert';

import '../../lowering/plan.dart';
import 'arguments.dart';
import 'structural.dart';
import 'settlement.dart';

String emitBoundary(ModulePlan plan) {
  final conversions = plan.conversions;
  final resources = plan.resourcePolicies.isNotEmpty;
  final policies = [
    for (final c in conversions)
      if (c is ScalarConversion) scalarPolicy(c) else null,
  ];
  final outputs = {for (final call in plan.calls) ?call.outputContext};
  final callbacks = {
    for (final (index, conversion) in conversions.indexed)
      if (conversion is CallbackConversion) index: conversion,
  };
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
          leafAdapter: BoundaryLeafAdapter(resources: resources),
          generateRead: !outputs.contains(index),
          generateWrite: outputs.contains(index),
        ),
  };
  return '''// Generated JS imports for the Wasm boundary, not a consumer entry.
${plan.classes.isEmpty ? '' : "import {readReference, writeReference} from './references.mjs';"}
${resources ? '$settlementObserver\n' : ''}const policies = ${jsonEncode(policies)};
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
export function readValue(value, context${resources ? ', operation = null' : ''}) {
  switch (context) {
${[for (final e in structures.entries)
    if (e.value.read != null) '    case ${e.key}: return ${e.value.read}(value, ${jsonEncode(conversions[e.key].context)}, {work: 0, active: new Set()${resources ? ', operation' : ''}}, 0);'].join('\n')}
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
${plan.calls.any((call) => call.returnsFuture) ? '${emitFuturePolicy(resources: resources)}\n' : ''}${resources ? resourcePolicy : ''}${structures.isEmpty && callbacks.isEmpty ? '' : structuralPolicy}
${conversions.any(_containsMap) ? mapStructuralPolicy : ''}
${conversions.any(containsDictionary) ? dictionaryStructuralPolicy : ''}
${structures.values.map((s) => s.source).join('\n')}${callbacks.isEmpty ? '' : '\n${_emitCallbacks(callbacks, futures: plan.calls.any((call) => call.returnsFuture))}'}
${plan.classes.isNotEmpty || plan.functions.any((f) => f.representation == ExportRepresentation.callableGlobal) ? argumentPolicy : ''}
''';
}

String _emitCallbacks(
  Map<int, CallbackConversion> callbacks, {
  required bool futures,
}) {
  final source = StringBuffer(r'''
const callbackApply = Reflect.apply;
export function borrowCallback(frame, value, nullable, path) {
  if (value === null && nullable) return null;
  if (typeof value !== 'function') throw new TypeError(path + ': expected function' + (nullable ? ' or null' : ''));
  const state = {fn: value, path};
  Object.defineProperty(frame, frame.length, {value: state, configurable: true});
  return state;
}
export function expireCallbacks(frame) {
  for (let i = 0; i < frame.length; i++) frame[i].fn = null;
  frame.length = 0;
}
export function callbackActive(state) { return state.fn === null ? 0 : 1; }
export function callbackThrew(envelope) { return envelope.threw ? 1 : 0; }
export function callbackValue(envelope) { return envelope.value; }
export function throwCallbackError(envelope) { throw envelope.value; }
export function callbackStructureError(path, message, range) {
  return {threw: true, value: range ? new RangeError(path + ': ' + message) : new TypeError(path + ': ' + message)};
}
export function invokeCallback(state, values, context) {
  try {
    const callback = state.fn;
    if (callback === null) throw new Error(state.path + ': borrowed callback has expired');
    switch (context) {
''');
  final converters = StringBuffer();
  for (final entry in callbacks.entries) {
    final id = entry.key;
    final callback = entry.value;
    final arguments = <String>[];
    for (final (index, conversion) in callback.inputs.indexed) {
      final boundary = emitStructuralBoundary(
        conversion,
        prefix: 'callback${id}Argument$index',
        generateRead: false,
      );
      converters.writeln(boundary.source);
      arguments.add(
        '${boundary.write}(values[$index], ${jsonEncode(conversion.context)}, {work: 0, active: new Set(), pending: null}, 0)',
      );
    }
    source.writeln('      case $id: {');
    source.writeln('        const args = [${arguments.join(', ')}];');
    if (callback.output case final output?) {
      final boundary = emitStructuralBoundary(
        output,
        prefix: 'callback${id}Result',
        leafAdapter: const BoundaryLeafAdapter(bigintText: true),
        generateWrite: false,
      );
      converters.writeln(boundary.source);
      source.writeln(
        '        const value = callbackApply(callback, undefined, args);',
      );
      source.writeln(
        '        return {threw: false, value: ${boundary.read}(value, ${jsonEncode(output.context)}, {work: 0, active: new Set()}, 0)};',
      );
    } else {
      source.writeln('        callbackApply(callback, undefined, args);');
      source.writeln('        return {threw: false, value: undefined};');
    }
    source.writeln('      }');
  }
  source.writeln(
    '''      default: throw new Error('Unknown callback conversion context');
    }
  } catch (value) { return {threw: true, value}; }
}''',
  );
  if (futures) {
    source.writeln(
      'export function rejectCallbackPromise(capability, envelope) { rejectPromise(capability, envelope.value); }',
    );
  }
  source.write(converters);
  return source.toString();
}

/// Private capabilities keep conversion and JS exception handling in JS. Their
/// raw Dart roots last through resolver handoff, including then-getter reentry.
String emitFuturePolicy({bool resources = false}) =>
    '''
const capturedPromise = globalThis.Promise;
const pendingPromises = new Set();
export function createPromise(wrap = null) {
  let resolve, reject;
  const promise = new capturedPromise((accept, fail) => { resolve = accept; reject = fail; });
  return {promise, resolve, reject, wrap, roots: null, done: false${resources ? ', release: null, hasOperation: false, observed: false' : ''}};
}
export function retainPromise(capability, roots) {
  capability.roots = roots;
  pendingPromises.add(capability);
}
function releasePromise(capability) {
  pendingPromises.delete(capability);
${resources ? '  const release = capability.release;\n  capability.release = null;\n  capability.retain = null;\n' : ''}  capability.roots = null;
  capability.wrap = null;
  capability.resolve = null;
  capability.reject = null;
${resources ? '  if (release !== null) release();\n' : ''}}
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
${resources ? '''    const output = capability.wrap === null ? value : capability.wrap(value);
    if (capability.hasOperation && output !== null && (typeof output === 'object' || typeof output === 'function')) {
      resourceSettlements.observe(capability.promise, capability);
      capability.observed = true;
    }
    capability.resolve(output);''' : '    capability.resolve(capability.wrap === null ? value : capability.wrap(value));'}
  } catch (error) {
    capability.reject(error);
  } finally {
${resources ? '''    if (capability.observed) {
      capability.wrap = null;
      capability.resolve = null;
      capability.reject = null;
    } else releasePromise(capability);''' : '    releasePromise(capability);'}
  }
}
''';

const resourcePolicy = r'''
const resourceSettlements = createSettlementObserver(releasePromise);
const cleanupPromises = new WeakMap();
export function resourcePolicyError() { throw new TypeError('Resource has incompatible cleanup policies'); }
export function createResourceCall() { return {release: null}; }
export function attachResourceOperation(capability, release, retain) {
  capability.release = release;
  capability.retain = retain;
}
export function readResourceValue(capability, value, context) { return readValue(value, context, capability); }
export function retainResourceReference(capability, reference) {
  capability.retain(reference);
  return reference;
}
function readResourceReference(value, classId, nullable, path, capability) {
  const reference = readReference(value, classId, nullable, path);
  if (capability !== null) capability.retain(reference);
  return reference;
}
export function activateResourceOperation(capability, active) {
  capability.hasOperation = active !== 0;
}
export function finishResourceCall(capability) {
  if ((capability.promise !== undefined && !capability.done) || capability.observed) return;
  releasePromise(capability);
}
export function bindCleanup(capability, control) {
  const previous = cleanupPromises.get(control)?.deref();
  if (previous !== undefined) {
    capability.promise = previous;
    capability.done = true;
    return 0;
  }
  cleanupPromises.set(control, new WeakRef(capability.promise));
  return 1;
}
''';

bool _containsMap(ValueConversion value) =>
    conversionGraph([value]).any((c) => c is MapConversion);
