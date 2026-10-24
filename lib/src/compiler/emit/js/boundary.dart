import 'dart:convert';

import '../../lowering/plan.dart';
import '../../ir/model.dart' show ClassBinding;
import 'arguments.dart';
import 'binary.dart';
import 'callbacks.dart';
import 'cancellation.dart';
import 'structural.dart';
import 'settlement.dart';
import 'shared_bytes.dart';
import 'js_collections.dart';
import 'opaque.dart';
import 'streams.dart';

String emitBoundary(ModulePlan plan, {bool browser = false}) {
  final conversions = plan.conversions;
  final resources = plan.resourcePolicies.isNotEmpty;
  final functionContracts = {
    for (final call in plan.functionValues)
      call.conversion.signatureKey: call.contractId,
  };
  final nestedOpaque = conversionDependencies(plan.conversions).any(
    (root) =>
        root is! OpaqueConversion &&
        conversionGraph([root]).any((leaf) => leaf is OpaqueConversion),
  );
  final streams = plan.calls.any((call) => call.returnsStream);
  final signals = conversions.any((c) => c is AbortSignalConversion);
  final sharedBytes = {
    for (final (index, conversion) in conversions.indexed)
      if (conversion is SharedBytesConversion) index: conversion,
  };
  final jsCollections = {
    for (final (index, conversion) in conversions.indexed)
      if (conversion is JsCollectionConversion) index: conversion,
  };
  final jsCollectionLeaves = conversionGraph(conversions)
      .whereType<JsCollectionConversion>()
      .toList();
  final hasOpaque =
      jsCollectionLeaves.isNotEmpty ||
      conversionDependencies(conversions).any((c) => c is OpaqueConversion) ||
      plan.functions.any(
        (f) => f.binding.typeParameters.any((p) => p.opaque),
      ) ||
      plan.classes.any(
        (c) =>
            c.binding.typeParameters.any((p) => p.opaque) ||
            c.members.any((m) => m.binding.typeParameters.any((p) => p.opaque)),
      );
  final collectionStructures = jsCollectionStructurePolicies(
    jsCollectionLeaves,
    resources: resources,
    classes: plan.allClasses,
    functionContracts: functionContracts,
  );
  final binaries = {
    for (final (index, conversion) in conversions.indexed)
      if (conversion is BinaryConversion) index: conversion,
  };
  final hasBinary = conversionDependencies(conversions)
      .any((c) => c is BinaryConversion);
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
          leafAdapter: BoundaryLeafAdapter(
            resources: resources,
            classes: plan.allClasses,
            functionContracts: functionContracts,
          ),
          generateRead: !outputs.contains(index),
          generateWrite: outputs.contains(index),
        ),
  };
  return '''// Generated JS imports for the Wasm boundary, not a consumer entry.
${plan.classes.isEmpty
      ? ''
      : browser
      ? _browserReferences(plan)
      : "import {readReference, writeReference} from './references.mjs';"}
${callbacks.isEmpty ? '' : "import {writeFunction, registerCallbackSource} from './${browser ? 'browser-' : ''}references.mjs';\nexport {unwrapFunction} from './${browser ? 'browser-' : ''}references.mjs';"}
${jsCollectionLeaves.isEmpty ? '' : '${browser ? browserJsCollectionsPolicy : jsCollectionsPolicy}\nconst \$jcPolicies = ${jsCollectionPolicies(jsCollectionLeaves)};\n$wasmJsCollectionsPolicy\n'}${browser ? browserSharedBytesPolicy : sharedBytesPolicy}
$wasmSharedBytesPolicy
${hasOpaque ? '$opaqueKeyPolicy\n$wasmOpaqueKeyPolicy' : ''}
${nestedOpaque ? '$opaqueStructuralPolicy\n' : ''}${signals ? '${browser ? browserCancellationPolicy : cancellationPolicy}\n$wasmCancellationPolicy' : ''}
${hasBinary ? '${browser ? browserBinaryPolicy : binaryPolicy}\n$wasmBinaryPolicy' : ''}
${resources ? '${browser ? browserSettlementObserver : settlementObserver}\n' : ''}const policies = ${jsonEncode(policies)};
const scalarIsSafeInteger = Number.isSafeInteger;
const scalarBigInt = BigInt, scalarBigIntText = BigInt.prototype.toString, scalarApply = Reflect.apply;
function checkedScalar(value, policy, path) {
  if (value === null && policy.nullable) return null;
  if (typeof value !== policy.type) {
    throw new TypeError(path + ': expected a JavaScript ' + policy.type + (policy.nullable ? ' or null' : ''));
  }
  if (policy.integer) {
    if (policy.type === 'number' && !scalarIsSafeInteger(value)) {
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
${jsCollections.entries.map((e) => '    case ${e.key}: return \$jcAdmit(value, ${e.value.isMap}, ${e.value.nullable}, ${jsonEncode(e.value.context)});\n').join()}${[for (final e in sharedBytes.entries) '    case ${e.key}: return \$napiReadSharedBytes(value, ${e.value.nullable}, ${jsonEncode(e.value.context)});'].join('\n')}
${[for (final e in binaries.entries) '    case ${e.key}: return \$napiCopyBinary(value, ${e.value.kind.index}, ${e.value.nullable}, ${jsonEncode(e.value.context)}, true);'].join('\n')}
${[for (final e in callbacks.entries) '    case ${e.key}: return checkCallback(value, ${e.value.nullable}, ${jsonEncode(e.value.context)});'].join('\n')}
${[for (final e in structures.entries)
    if (e.value.read != null) '    case ${e.key}: return ${e.value.read}(value, ${jsonEncode(conversions[e.key].context)}, {work: 0, active: new Set()${resources ? ', operation' : ''}}, 0);'].join('\n')}
    default: return checked(value, context);
  }
}
export function writeValue(value, context) {
  switch (context) {
${jsCollections.entries.map((e) => '    case ${e.key}: return \$jcAdmit(value, ${e.value.isMap}, ${e.value.nullable}, ${jsonEncode(e.value.context)});\n').join()}${[for (final e in sharedBytes.entries) '    case ${e.key}: return \$napiReadSharedBytes(value, ${e.value.nullable}, ${jsonEncode(e.value.context)});'].join('\n')}
${[for (final e in binaries.entries) '    case ${e.key}: return \$napiAdoptBinary(value, ${e.value.kind.index}, ${e.value.nullable}, ${jsonEncode(e.value.context)});'].join('\n')}
${[for (final e in callbacks.entries) '    case ${e.key}: return value === null && ${e.value.nullable} ? null : writeFunction(value, ${functionContracts[e.value.signatureKey]}, ${jsonEncode(e.value.context)});'].join('\n')}
${[for (final e in structures.entries)
    if (e.value.write != null) '    case ${e.key}: {\n      const state = {work: 0, active: new Set(), pending: null};\n      try { return ${e.value.write}(value, ${jsonEncode(conversions[e.key].context)}, state, 0); }\n      catch (error) { if (state.pending !== null) { for (const undo of state.pending) undo(); } throw error; }\n    }'].join('\n')}
    default: return checked(value, context);
  }
}
// Called only after checked() has established a primitive bigint. Decimal
// text avoids any precision-losing conversion through a JavaScript number.
export function readBigInt(value) { return scalarApply(scalarBigIntText, value, []); }
export function writeBigInt(value, context) { return checked(scalarBigInt(value), context); }
export function throwDartError(message) { throw new Error(message); }
${plan.calls.any((call) => call.returnsFuture) || streams ? '${emitFuturePolicy(resources: resources, streams: streams)}\n' : ''}${resources
      ? browser
            ? browserResourcePolicy
            : resourcePolicy
      : ''}${streams ? streamBoundaryPolicy(references: plan.classes.isNotEmpty) : ''}${structures.isEmpty && callbacks.isEmpty && collectionStructures.isEmpty
      ? hasBinary || sharedBytes.isNotEmpty || jsCollections.isNotEmpty
            ? structuralErrorPolicy
            : ''
      : structuralPolicy}
${conversionDependencies(conversions).any((c) => c is MapConversion) ? mapStructuralPolicy : ''}
${conversionDependencies(conversions).any((c) => c is DictionaryConversion) ? dictionaryStructuralPolicy : ''}
$collectionStructures${structures.values.map((s) => s.source).join('\n')}${callbacks.isEmpty ? '' : '\n${_emitCallbacks({for (final entry in callbacks.entries)
          if (entry.value.direction == ValueDirection.input) entry.key: entry.value}, resources: resources, classes: plan.allClasses, functionContracts: functionContracts, browser: browser)}'}
${_emitCallbackErrors(futures: plan.calls.any((call) => call.returnsFuture) || streams)}
${plan.classes.isNotEmpty || plan.functions.any((f) => f.representation == ExportRepresentation.callableGlobal) ? argumentPolicy : ''}
''';
}

String _emitCallbacks(
  Map<int, CallbackConversion> callbacks, {
  required bool resources,
  required List<ClassBinding> classes,
  required Map<String, int> functionContracts,
  bool browser = false,
}) {
  final asynchronous = callbacks.values.any(
    (callback) => callback.returnsFuture || callback.returnsStream,
  );
  final streams = callbacks.values.any((callback) => callback.returnsStream);
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
  registerCallbackSource(adapter, signature, callbackApply(callbackMapGet, callbackWireSignatures, [signature]), callback);
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
  source.writeln(
    'const callbackWireSignatures = new callbackMap(${jsonEncode([
      for (final callback in callbacks.values) [callback.signatureKey, callback.wireSignatureKey],
    ])});',
  );
  if (callbacks.values.any((callback) => callback.hasParameterShape)) {
    source.writeln(r'''
const callbackCreate = Object.create;
const callbackDefine = Object.defineProperty;
''');
  }
  if (resources) {
    source.writeln(r'''
function writeCallbackReference(value, classId, path, state) {
  state.operation.retain(value);
  return writeReference(value, classId, path, state.pending ??= new Set());
}
''');
  }
  if (asynchronous) {
    source.writeln(
      browser ? browserCallbackPromisePolicy : callbackPromisePolicy,
    );
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
  if (streams) source.writeln(callbackStreamPolicy);
  final synchronousCases = StringBuffer();
  final asynchronousCases = StringBuffer();
  final streamCases = StringBuffer();
  for (final entry in callbacks.entries) {
    final id = entry.key;
    final callback = entry.value;
    final mapped = callback.hasParameterShape;
    final optional = [
      for (final (index, _) in callback.parameters.indexed)
        if (callback.isOptionalParameter(index)) index,
    ];
    String present(int index) =>
        'values[${callback.inputs.length + optional.indexOf(index)}]';
    final arguments = <String>[];
    for (final (index, conversion) in callback.inputs.indexed) {
      final boundary = emitStructuralBoundary(
        conversion,
        prefix: 'callback${id}Argument$index',
        leafAdapter: _CallbackLeafAdapter(resources, functionContracts),
        generateRead: false,
      );
      source.writeln(boundary.source);
      arguments.add(
        '${boundary.write}(values[$index], ${jsonEncode(conversion.context)}, state, 0)',
      );
    }
    var read = 'undefined';
    if (callback.output case final output?) {
      final boundary = emitStructuralBoundary(
        output,
        prefix: 'callback${id}Result',
        leafAdapter: BoundaryLeafAdapter(
          resources: resources,
          classes: classes,
          bigintText: true,
          functionContracts: functionContracts,
        ),
        generateWrite: false,
      );
      source.writeln(boundary.source);
      read =
          '${boundary.read}(value, ${jsonEncode(output.context)}, {work: 0, active: new Set()${resources ? ', operation' : ''}}, 0)';
    }
    if (callback.returnsStream) {
      streamCases.writeln('''      case $id: {
        const value = result.value;
        return {threw: false, done: false, value: $read};
      }''');
    }
    final cases = callback.returnsFuture ? asynchronousCases : synchronousCases;
    cases.writeln('      case $id: {');
    for (final (index, argument) in arguments.indexed) {
      if (index != 0) cases.writeln('        state.work = 0;');
      cases.writeln(
        '        const arg$index = ${optional.contains(index) ? '${present(index)} ? $argument : undefined' : argument};',
      );
    }
    if (!mapped) {
      cases.writeln(
        '        const args = [${[for (var index = 0; index < arguments.length; index++) 'arg$index'].join(', ')}];',
      );
    } else {
      final required = [
        for (final (index, _) in callback.parameters.indexed)
          if (!callback.isOptionalParameter(index) &&
              !callback.isNamedParameter(index))
            'arg$index',
      ];
      cases.writeln('        const args = [${required.join(', ')}];');
      String append(String array, String key, String value) =>
          'callbackDefine($array, $key, {__proto__: null, value: $value, enumerable: true, writable: true, configurable: true});';
      for (final (index, _) in callback.parameters.indexed) {
        if (callback.isOptionalParameter(index) &&
            !callback.isNamedParameter(index)) {
          cases.writeln(
            '        if (${present(index)}) ${append('args', 'args.length', 'arg$index')}',
          );
        }
      }
      final named = [
        for (final (index, _) in callback.parameters.indexed)
          if (callback.isNamedParameter(index)) index,
      ];
      named.sort(
        (a, b) =>
            callback.parameters[a].name.compareTo(callback.parameters[b].name),
      );
      if (named.isNotEmpty) {
        final anyNamed = named.any((index) => !optional.contains(index))
            ? 'true'
            : named.map(present).join(' || ');
        cases.writeln(
          '        if ($anyNamed) {\n          const options = callbackCreate(null);',
        );
        for (final index in named) {
          cases.writeln(
            '          ${optional.contains(index) ? 'if (${present(index)}) ' : ''}${append('options', jsonEncode(callback.parameters[index].name), 'arg$index')}',
          );
        }
        cases.writeln(
          '          ${append('args', 'args.length', 'options')}\n        }',
        );
      }
    }
    cases.writeln('        state.pending = null;');
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
    } else if (callback.returnsStream) {
      cases.writeln(
        '        return {threw: false, value: \$napiOpenCallbackStream(value)};',
      );
    } else {
      cases.writeln('        return {threw: false, value: $read};');
    }
    cases.writeln('      }');
  }
  source.writeln('''
export function invokeCallback(callback, values, context${resources ? ', retain' : ''}) {
${resources ? '  const operation = {retain};\n' : ''}  const state = {work: 0, active: null, pending: null${resources ? ', operation' : ''}};
  try {
    state.active = new Set();
    switch (context) {
$synchronousCases      default: throw new Error('Unknown callback conversion context');
    }
  } catch (value) {
    if (state.pending !== null) { for (const undo of state.pending) undo(); }
    return {threw: true, value};
  }
}''');
  if (asynchronous) {
    source.writeln('''
export function startCallback(callback, values, context, deliver, roots${resources ? ', retain' : ''}) {
${resources ? '  const operation = {retain};\n' : ''}  const state = {work: 0, active: null, pending: null${resources ? ', operation' : ''}};
  const record = {callback, promise: null, deliver, roots, done: false};
  callbackApply(pendingCallbackAdd, pendingCallbacks, [record]);
  try {
    state.active = new Set();
    switch (context) {
$asynchronousCases      default: throw new Error('Unknown async callback conversion context');
    }
  } catch (value) {
    if (state.pending !== null) { for (const undo of state.pending) undo(); }
    releaseCallback(record);
    return {threw: true, value};
  }
}''');
  }
  if (streams) {
    source.writeln('''
export function callbackStreamDone(envelope) { return envelope.done ? 1 : 0; }
export function startCallbackStream(control, cancel, context, deliver, roots${resources ? ', retain' : ''}) {
${resources ? '  const operation = {retain};\n' : ''}  const record = {callback: control, promise: null, deliver, roots, done: false};
  callbackApply(pendingCallbackAdd, pendingCallbacks, [record]);
  try {
    record.promise = control(cancel !== 0);
    \$napiObserveCallbackPromise(record.promise, result => {
      let envelope;
      try {
        envelope = (() => {
          if (result.done) return {threw: false, done: true};
          switch (context) {
$streamCases          default: throw new Error('Unknown stream callback conversion context');
          }
        })();
      } catch (value) { envelope = {threw: true, value}; }
      settleCallback(record, envelope);
    }, value => { settleCallback(record, {threw: true, value}); });
    return null;
  } catch (value) {
    releaseCallback(record);
    return {threw: true, value};
  }
}''');
  }
  return source.toString();
}

final class _CallbackLeafAdapter implements StructuralLeafAdapter {
  final bool resources;
  final Map<String, int> functionContracts;
  const _CallbackLeafAdapter(this.resources, this.functionContracts);

  @override
  String read(ValueConversion leaf, String value, String path) =>
      BoundaryLeafAdapter(functionContracts: functionContracts)
          .read(leaf, value, path);

  @override
  String write(ValueConversion leaf, String value, String path) =>
      resources && leaf is ReferenceConversion
      ? 'writeCallbackReference($value, ${leaf.classId}, $path, state)'
      : BoundaryLeafAdapter(functionContracts: functionContracts)
            .write(leaf, value, path);
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

const resourcePolicy =
    _resourcePolicyStart + _resourceActivation + _resourcePolicyEnd;
const browserResourcePolicy =
    _resourcePolicyStart + _browserResourceActivation + _resourcePolicyEnd;

const _resourcePolicyStart = r'''
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
''';

const _resourceActivation =
    r'''export function activateResourceOperation(capability, active) {
  capability.hasOperation = active !== 0;
}
''';

const _browserResourceActivation =
    r'''export function activateResourceOperation(capability, active) {
  if (active !== 0) throw new TypeError('Resource policies are not supported by browser bindings');
  capability.hasOperation = false;
}
''';

const _resourcePolicyEnd = r'''export function finishResourceCall(capability) {
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

String _browserReferences(ModulePlan plan) => plan.resourcePolicies.isEmpty
    ? "import {readReference, writeReference} from './browser-references.mjs';"
    : """import {readReference as readBrowserReference, writeReference as writeBrowserReference} from './browser-references.mjs';
const browserResourceClasses = new Set(${jsonEncode(plan.resourcePolicies.keys.toList())});
const browserResourceHas = Set.prototype.has, browserResourceApply = Reflect.apply;
function browserReferencePolicy(classId) {
  if (browserResourceApply(browserResourceHas, browserResourceClasses, [classId])) {
    throw new TypeError('Resource policies are not supported by browser bindings');
  }
}
function readReference(value, classId, nullable, path) {
  browserReferencePolicy(classId);
  return readBrowserReference(value, classId, nullable, path);
}
function writeReference(value, classId, path, pending) {
  browserReferencePolicy(classId);
  return writeBrowserReference(value, classId, path, pending);
}
""";
