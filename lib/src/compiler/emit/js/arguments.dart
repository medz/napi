import 'dart:convert';

import '../../ir/model.dart';
import '../../lowering/plan.dart';

/// Presence stays separate from conversion: opaque undefined/null are values.
/// The opaque engine can use this policy without adopting scalar nullish rules.
const argumentPolicy = r'''
export function useDefault(value, supplied, policy, context) {
  switch (policy) {
    case 'optional': return !supplied || value === undefined;
    case 'opaqueOptional': return !supplied;
    case 'required':
    case 'opaqueRequired':
      if (!supplied || (policy === 'required' && value === undefined)) {
        throw new TypeError(context + ': missing required argument');
      }
      return false;
    default: throw new Error('Unknown argument presence policy: ' + policy);
  }
}
export function readOptions(value, supplied, names, context) {
  if (!supplied || value === undefined) return Object.create(null);
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new TypeError(context + ': expected an options object');
  }
  const prototype = Object.getPrototypeOf(value);
  if (prototype !== null && prototype !== Object.prototype) {
    throw new TypeError(context + ': expected an options object');
  }
  const properties = Object.getOwnPropertyDescriptors(value);
  for (const key of Reflect.ownKeys(properties)) {
    if (typeof key !== 'string' || !names.has(key)) {
      throw new TypeError(context + ': unknown named argument ' + String(key));
    }
    if (!Object.hasOwn(properties[key], 'value')) {
      throw new TypeError(context + '.' + key + ': expected an own data property');
    }
  }
  return properties;
}
''';

/// These callables are imported as immutable globals by the public Wasm module.
/// The private dependency only calls the Dart core after capturing JS presence.
String emitArgumentCalls(ModulePlan plan) {
  final result = StringBuffer('''// Generated private callable dependency.
import * as core from './core.wasm';
import {useDefault, readOptions} from './boundary.mjs';
''');
  for (final (index, function) in plan.functions.indexed) {
    if (function.representation != ExportRepresentation.callableGlobal) {
      continue;
    }
    final parameters = function.binding.parameters;
    final named = parameters.where((p) => _named(p)).toList();
    final positionalCount = parameters.length - named.length;
    if (named.isNotEmpty) {
      result.writeln(
        'const names$index = new Set('
        '${jsonEncode(named.map((p) => p.name).toList())});',
      );
    }
    result.writeln('const call$index = (...args) => {');
    // Capture own property descriptors once; accessors are never invoked.
    if (named.isNotEmpty) {
      result.writeln(
        '  const options = readOptions(args[$positionalCount], '
        'args.length > $positionalCount, '
        'names$index, '
        '${jsonEncode('${function.binding.exportName} options')});',
      );
    }
    for (final (i, parameter) in parameters.indexed) {
      final key = jsonEncode(parameter.name);
      final supplied = _named(parameter)
          ? 'Object.hasOwn(options, $key)'
          : 'args.length > $i';
      result.writeln('  const s$i = $supplied;');
      result.writeln(
        '  const p$i = ${_named(parameter) ? 's$i ? options[$key].value : undefined' : 'args[$i]'};',
      );
      result.writeln(
        '  const d$i = useDefault(p$i, s$i, '
        '${jsonEncode(parameter.presence.name)}, '
        '${jsonEncode(function.inputs[i].context)});',
      );
    }
    result.writeln(
      '  return core[${jsonEncode(function.coreExportName)}]('
      '${[
        for (final (i, p) in parameters.indexed) ...[if (_optional(p)) 'd$i ? 1 : 0', 'p$i'],
      ].join(', ')});',
    );
    result.writeln(
      '};\nexport {call$index as ${function.binding.exportName}};',
    );
  }
  return result.toString();
}

bool _named(ParameterBinding p) =>
    p.kind == ParameterKind.requiredNamed ||
    p.kind == ParameterKind.optionalNamed;
bool _optional(ParameterBinding p) =>
    p.kind == ParameterKind.optionalNamed ||
    p.kind == ParameterKind.optionalPositional;
