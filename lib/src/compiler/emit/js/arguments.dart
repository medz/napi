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
  final names = <CallPlan, String>{};
  for (final (index, call) in plan.calls.indexed) {
    final named = call.parameters.where(_named);
    if (named.isEmpty) continue;
    names[call] = 'names$index';
    result.writeln(
      'const names$index = new Set('
      '${jsonEncode(named.map((p) => p.name).toList())});',
    );
  }
  for (final (index, function) in plan.functions.indexed) {
    if (function.representation != ExportRepresentation.callableGlobal) {
      continue;
    }
    result.writeln('const call$index = (...args) => {');
    final arguments = _arguments(
      result,
      function,
      function.binding.exportName,
      names[function],
    );
    result.writeln(
      '  return core[${jsonEncode(function.coreExportName)}]('
      '$arguments);',
    );
    result.writeln(
      '};\nexport {call$index as ${function.binding.exportName}};',
    );
  }
  for (final (index, binding) in plan.classes.indexed) {
    final local = 'class$index';
    result.writeln('class $local {\n  #reference;\n  constructor(...args) {');
    final arguments = _arguments(
      result,
      binding.constructor,
      binding.binding.exportName,
      names[binding.constructor],
      indent: '    ',
    );
    result.writeln(
      '    this.#reference = core[${jsonEncode(binding.constructor.coreExportName)}]($arguments);\n  }',
    );
    for (final member in binding.members) {
      final prefix = member.isStatic ? 'static ' : '';
      final name = jsonEncode(member.exportName);
      final declaration = switch (member.kind) {
        MemberCallKind.method => '$prefix[$name](...args)',
        MemberCallKind.getter => '${prefix}get [$name]()',
        MemberCallKind.setter => '${prefix}set [$name](value)',
        MemberCallKind.constructor => throw StateError(
          'Unexpected constructor',
        ),
      };
      result.writeln('  $declaration {');
      // A private field rejects forged, foreign and Proxy receivers before any
      // options inspection or Dart call, while retaining the Dart object itself.
      if (!member.isStatic) {
        result.writeln('    const reference = this.#reference;');
      }
      if (member.kind == MemberCallKind.setter) {
        result.writeln('    const args = [value];');
      }
      final arguments = _arguments(
        result,
        member,
        member.context,
        names[member],
        indent: '    ',
      );
      result.writeln(
        '    ${member.output == null ? '' : 'return '}core[${jsonEncode(member.coreExportName)}]('
        '${[if (!member.isStatic) 'reference', if (arguments.isNotEmpty) arguments].join(', ')});\n  }',
      );
    }
    result.writeln('}');
    if (!binding.members.any(
      (member) => member.isStatic && member.exportName == 'name',
    )) {
      result.writeln(
        'Object.defineProperty($local, "name", {value: ${jsonEncode(binding.binding.exportName)}, configurable: true});',
      );
    }
    result.writeln(
      'Object.defineProperty($local, "length", {value: ${_arity(binding.constructor)}, configurable: true});',
    );
    for (final member in binding.members) {
      if (member.kind != MemberCallKind.method) continue;
      final receiver = member.isStatic ? local : '$local.prototype';
      result.writeln(
        'Object.defineProperty(Object.getOwnPropertyDescriptor($receiver, ${jsonEncode(member.exportName)}).value, "length", {value: ${_arity(member)}, configurable: true});',
      );
    }
    result.writeln('export {$local as ${binding.binding.exportName}};');
  }
  return result.toString();
}

String _arguments(
  StringBuffer result,
  CallPlan call,
  String context,
  String? names, {
  String indent = '  ',
}) {
  final parameters = call.parameters;
  final positionalCount = parameters.where((p) => !_named(p)).length;
  // Capture own property descriptors once; accessors are never invoked.
  if (names != null) {
    result.writeln(
      '${indent}const options = readOptions(args[$positionalCount], '
      'args.length > $positionalCount, $names, '
      '${jsonEncode('$context options')});',
    );
  }
  for (final (i, parameter) in parameters.indexed) {
    final key = jsonEncode(parameter.name);
    final supplied = _named(parameter)
        ? 'Object.hasOwn(options, $key)'
        : 'args.length > $i';
    result.writeln('${indent}const s$i = $supplied;');
    result.writeln(
      '${indent}const p$i = ${_named(parameter) ? 's$i ? options[$key].value : undefined' : 'args[$i]'};',
    );
    result.writeln(
      '${indent}const d$i = useDefault(p$i, s$i, '
      '${jsonEncode(parameter.presence.name)}, '
      '${jsonEncode(call.inputs[i].context)});',
    );
  }
  return [
    for (final (i, p) in parameters.indexed) ...[
      if (_optional(p)) 'd$i ? 1 : 0',
      'p$i',
    ],
  ].join(', ');
}

int _arity(CallPlan call) =>
    call.parameters.any((p) => p.kind != ParameterKind.requiredPositional)
    ? 0
    : call.parameters.length;

bool _named(ParameterBinding p) =>
    p.kind == ParameterKind.requiredNamed ||
    p.kind == ParameterKind.optionalNamed;
bool _optional(ParameterBinding p) =>
    p.kind == ParameterKind.optionalNamed ||
    p.kind == ParameterKind.optionalPositional;
