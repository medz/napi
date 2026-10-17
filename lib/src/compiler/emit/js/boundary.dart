import 'dart:convert';

import '../../lowering/plan.dart';
import 'arguments.dart';
import 'callbacks.dart';
import 'cancellation.dart';
import 'structural.dart';
import 'settlement.dart';
import 'streams.dart';

String emitBoundary(ModulePlan plan) {
  final conversions = plan.conversions;
  final resources = plan.resourcePolicies.isNotEmpty;
  final streams = plan.calls.any((call) => call.returnsStream);
  final signals = conversions.any((c) => c is AbortSignalConversion);
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
${signals ? '$cancellationPolicy\n$wasmCancellationPolicy' : ''}
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
${plan.calls.any((call) => call.returnsFuture) || streams ? '${emitFuturePolicy(resources: resources, streams: streams)}\n' : ''}${resources ? resourcePolicy : ''}${streams ? streamBoundaryPolicy(references: plan.classes.isNotEmpty) : ''}${structures.isEmpty && callbacks.isEmpty ? '' : structuralPolicy}
${conversions.any(_containsMap) ? mapStructuralPolicy : ''}
${conversions.any(containsDictionary) ? dictionaryStructuralPolicy : ''}
${structures.values.map((s) => s.source).join('\n')}${callbacks.isEmpty ? '' : '\n${_emitCallbacks(callbacks)}'}
${callbacks.isNotEmpty || signals ? _emitCallbackErrors(futures: plan.calls.any((call) => call.returnsFuture) || streams) : ''}
${plan.classes.isNotEmpty || plan.functions.any((f) => f.representation == ExportRepresentation.callableGlobal) ? argumentPolicy : ''}
''';
}

String _emitCallbacks(Map<int, CallbackConversion> callbacks) {
  final asynchronous = callbacks.values.any(
    (callback) => callback.returnsFuture,
  );
  final source = StringBuffer(r'''
const callbackApply = Reflect.apply;
const callbackAdapters = new WeakMap();
const callbackWeakMapGet = WeakMap.prototype.get;
const callbackWeakMapSet = WeakMap.prototype.set;
const callbackMap = Map;
const callbackMapGet = Map.prototype.get;
const callbackMapSet = Map.prototype.set;
const callbackWeakRef = WeakRef;
const callbackDeref = WeakRef.prototype.deref;
export function checkCallback(value, nullable, path) {
  if (value === null && nullable) return null;
  if (typeof value !== 'function') throw new TypeError(path + ': expected function' + (nullable ? ' or null' : ''));
  return value;
}
export function findCallbackAdapter(callback, signature) {
  const entries = callbackApply(callbackWeakMapGet, callbackAdapters, [callback]);
  const reference = entries === undefined ? undefined : callbackApply(callbackMapGet, entries, [signature]);
  return reference === undefined ? null : callbackApply(callbackDeref, reference, []) ?? null;
}
export function cacheCallbackAdapter(callback, signature, adapter) {
  let entries = callbackApply(callbackWeakMapGet, callbackAdapters, [callback]);
  if (entries === undefined) {
    entries = new callbackMap();
    callbackApply(callbackWeakMapSet, callbackAdapters, [callback, entries]);
  }
  callbackApply(callbackMapSet, entries, [signature, new callbackWeakRef(adapter)]);
}
export function callbackThrew(envelope) { return envelope.threw ? 1 : 0; }
export function callbackValue(envelope) { return envelope.value; }
export function callbackStructureError(path, message, range) {
  return {threw: true, value: range ? new RangeError(path + ': ' + message) : new TypeError(path + ': ' + message)};
}
''');
  if (asynchronous) {
    source.writeln(callbackPromisePolicy);
    source.writeln(r'''
const pendingCallbacks = new Set();
const pendingCallbackAdd = Set.prototype.add;
const pendingCallbackDelete = Set.prototype.delete;
function releaseCallback(record) {
  record.done = true;
  record.callback = null;
  record.promise = null;
  record.deliver = null;
  record.roots = null;
  callbackApply(pendingCallbackDelete, pendingCallbacks, [record]);
}
function settleCallback(record, envelope) {
  if (record.done) return;
  record.done = true;
  try { record.deliver(envelope); }
  finally { releaseCallback(record); }
}
''');
  }
  final synchronousCases = StringBuffer();
  final asynchronousCases = StringBuffer();
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
      source.writeln(boundary.source);
      arguments.add(
        '${boundary.write}(values[$index], ${jsonEncode(conversion.context)}, {work: 0, active: new Set(), pending: null}, 0)',
      );
    }
    var read = 'undefined';
    if (callback.output case final output?) {
      final boundary = emitStructuralBoundary(
        output,
        prefix: 'callback${id}Result',
        leafAdapter: const BoundaryLeafAdapter(bigintText: true),
        generateWrite: false,
      );
      source.writeln(boundary.source);
      read =
          '${boundary.read}(value, ${jsonEncode(output.context)}, {work: 0, active: new Set()}, 0)';
    }
    final cases = callback.returnsFuture ? asynchronousCases : synchronousCases;
    cases.writeln('      case $id: {');
    cases.writeln('        const args = [${arguments.join(', ')}];');
    cases.writeln(
      '        const value = callbackApply(callback, undefined, args);',
    );
    if (callback.returnsFuture) {
      cases.writeln('''        record.promise = value;
        \$napiObserveCallbackPromise(value, value => {
          let envelope;
          try { envelope = {threw: false, value: $read}; }
          catch (value) { envelope = {threw: true, value}; }
          settleCallback(record, envelope);
        }, value => { settleCallback(record, {threw: true, value}); });
        return null;''');
    } else {
      cases.writeln('        return {threw: false, value: $read};');
    }
    cases.writeln('      }');
  }
  source.writeln('''
export function invokeCallback(callback, values, context) {
  try {
    switch (context) {
$synchronousCases      default: throw new Error('Unknown callback conversion context');
    }
  } catch (value) { return {threw: true, value}; }
}''');
  if (asynchronous) {
    source.writeln('''
export function startCallback(callback, values, context, deliver, roots) {
  const record = {callback, promise: null, deliver, roots, done: false};
  callbackApply(pendingCallbackAdd, pendingCallbacks, [record]);
  try {
    switch (context) {
$asynchronousCases      default: throw new Error('Unknown async callback conversion context');
    }
  } catch (value) {
    releaseCallback(record);
    return {threw: true, value};
  }
}''');
  }
  return source.toString();
}

String _emitCallbackErrors({required bool futures}) =>
    '''
export function throwCallbackError(envelope) { throw envelope.value; }
${futures ? 'export function rejectCallbackPromise(capability, envelope) { rejectPromise(capability, envelope.value); }' : ''}
''';

/// Private capabilities keep conversion and JS exception handling in JS. Their
/// raw Dart roots last through resolver handoff, including then-getter reentry.
String emitFuturePolicy({bool resources = false, bool streams = false}) =>
    '''
const capturedPromise = globalThis.Promise;
const pendingPromises = new Set();
const promiseApply = Reflect.apply;
const promiseSetAdd = Set.prototype.add;
const promiseSetDelete = Set.prototype.delete;
export function createPromise(wrap = null) {
  let resolve, reject;
  const promise = new capturedPromise((accept, fail) => { resolve = accept; reject = fail; });
  return {promise, resolve, reject, wrap, roots: null, done: false${resources || streams ? ', release: null' : ''}${streams ? ', streamFailure: null' : ''}${resources ? ', hasOperation: false, observed: false' : ''}};
}
export function retainPromise(capability, roots) {
  capability.roots = roots;
  promiseApply(promiseSetAdd, pendingPromises, [capability]);
}
function releasePromise(capability) {
  promiseApply(promiseSetDelete, pendingPromises, [capability]);
${resources || streams ? '  const release = capability.release;\n  capability.release = null;\n' : ''}${resources ? '  capability.retain = null;\n' : ''}${streams ? '  capability.streamFailure = null;\n' : ''}  capability.roots = null;
  capability.wrap = null;
  capability.resolve = null;
  capability.reject = null;
${resources || streams ? '  if (release !== null) release();\n' : ''}}
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
export function resolvePromiseValue(capability, value) {
${resources ? '''  const output = capability.wrap === null ? value : capability.wrap(value);
  if (capability.hasOperation && output !== null && (typeof output === 'object' || typeof output === 'function')) {
    resourceSettlements.observe(capability.promise, capability);
    capability.observed = true;
  }
  capability.resolve(output);''' : '  capability.resolve(capability.wrap === null ? value : capability.wrap(value));'}
}
export function completePromise(capability, convert) {
  if (capability.done) return;
  capability.done = true;
  try {
    if (convert === null) resolvePromiseValue(capability, undefined);
    else convert();
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
