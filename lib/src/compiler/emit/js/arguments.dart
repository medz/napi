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
  if (plan.classes.isNotEmpty) {
    result.writeln("import {registerReference} from './references.mjs';");
    result.writeln(r'''const wrappers = new WeakMap();
const owners = new WeakMap();
const adopt = Symbol();
function unwrap(value, classId, context, nullable) {
  if (value === null && nullable) return null;
  const owner = owners.get(value);
  if (owner === undefined || !memberships[owner.classId].has(classId)) {
    throw new TypeError(context + ': expected a local ' + classNames[classId]);
  }
  return owner.reference;
}
function intern(reference, expectedId, context, pending, receiver, newTarget) {
  const previous = wrappers.get(reference);
  const classId = previous === undefined ? core['napi:class:classify'](reference) : previous.classId;
  if (classId < 0) throw new TypeError(context + ': no unique most-specific selected class');
  if (!memberships[classId].has(expectedId)) {
    throw new TypeError(context + ': expected a local ' + classNames[expectedId]);
  }
  if (previous !== undefined) {
    const wrapper = previous.wrapper.deref();
    if (wrapper !== undefined) return wrapper;
  }
  const wrapper = receiver !== undefined && (newTarget !== constructors[expectedId] || classId === expectedId)
    ? receiver : new constructors[classId](adopt);
  owners.set(wrapper, {reference, classId});
  const entry = {classId, wrapper: new WeakRef(wrapper)};
  wrappers.set(reference, entry);
  if (previous === undefined && pending !== undefined) {
    pending.add(() => { if (wrappers.get(reference) === entry) wrappers.delete(reference); });
  }
  return wrapper;
}
''');
    result.writeln(
      'const memberships = [${plan.classes.map((c) => 'new Set(${jsonEncode(c.shape.memberships.toList())})').join(', ')}];',
    );
    result.writeln(
      'const classNames = ${jsonEncode(plan.classes.map((c) => c.binding.exportName).toList())};',
    );
    for (final (index, _) in plan.classes.indexed) {
      result.writeln(
        'const unwrap$index = (value, context, nullable) => unwrap(value, $index, context, nullable);',
      );
      result.writeln(
        'const wrap$index = (reference, context, pending) => reference === null ? null : intern(reference, $index, context, pending);',
      );
    }
  }
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
    final invocation =
        'core[${jsonEncode(function.coreExportName)}]($arguments)';
    result.writeln('  return ${_output(function.output, invocation)};');
    result.writeln(
      '};\nexport {call$index as ${function.binding.exportName}};',
    );
    result.writeln(
      'Object.defineProperty(call$index, "length", {value: ${_arity(function)}, configurable: true});',
    );
  }
  for (final (index, binding) in plan.classes.indexed) {
    final local = 'class$index';
    result.writeln(
      'class $local {\n  constructor(...args) {\n    if (args[0] === adopt) return;',
    );
    final constructor = binding.constructor;
    if (constructor == null) {
      result.writeln(
        '    throw new TypeError(${jsonEncode('${binding.binding.exportName}: no selected unnamed constructor')});',
      );
    } else {
      final arguments = _arguments(
        result,
        constructor,
        binding.binding.exportName,
        names[constructor],
        indent: '    ',
      );
      result.writeln(
        '    const reference = core[${jsonEncode(constructor.coreExportName)}]($arguments);',
      );
      result.writeln(
        '    return intern(reference, $index, ${jsonEncode(binding.binding.exportName)}, undefined, this, new.target);',
      );
    }
    result.writeln('  }');
    for (final member in binding.members) {
      final prefix = member.isStatic ? 'static ' : '';
      final name = jsonEncode(member.exportName);
      final declaration = switch (member.kind) {
        MemberCallKind.method => '$prefix[$name](...args)',
        MemberCallKind.getter => '${prefix}get [$name]()',
        MemberCallKind.setter => '${prefix}set [$name](value)',
        MemberCallKind.constructor => 'static [$name](...args)',
      };
      result.writeln('  $declaration {');
      // Module ownership and Dart membership precede options and business calls.
      if (!member.isStatic) {
        result.writeln(
          '    const reference = unwrap$index(this, ${jsonEncode(member.context)}, false);',
        );
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
      final invocation =
          'core[${jsonEncode(member.coreExportName)}](${[if (!member.isStatic) 'reference', if (arguments.isNotEmpty) arguments].join(', ')})';
      final expression = member.kind == MemberCallKind.constructor
          ? 'wrap$index($invocation, ${jsonEncode(member.context)})'
          : _output(member.output, invocation);
      result.writeln(
        '    ${member.output == null && member.kind != MemberCallKind.constructor ? '' : 'return '}$expression;\n  }',
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
      'Object.defineProperty($local, "length", {value: ${binding.constructor == null ? 0 : _arity(binding.constructor!)}, configurable: true});',
    );
    for (final member in binding.members) {
      if (member.kind != MemberCallKind.method &&
          member.kind != MemberCallKind.constructor) {
        continue;
      }
      final receiver = member.isStatic ? local : '$local.prototype';
      result.writeln(
        'Object.defineProperty(Object.getOwnPropertyDescriptor($receiver, ${jsonEncode(member.exportName)}).value, "length", {value: ${_arity(member)}, configurable: true});',
      );
    }
    result.writeln('export {$local as ${binding.binding.exportName}};');
  }
  if (plan.classes.isNotEmpty) {
    result.writeln(
      'const constructors = [${[for (final (index, _) in plan.classes.indexed) 'class$index'].join(', ')}];',
    );
    // Capture selected own callbacks before completing inherited accessors.
    result.writeln('const members = [');
    for (final (classId, binding) in plan.classes.indexed) {
      result.writeln(
        '  [${[for (final member in binding.members)
          if (member.isStatic) 'undefined' else 'Object.getOwnPropertyDescriptor(class$classId.prototype, ${jsonEncode(member.exportName)}).${switch (member.kind) {
              MemberCallKind.method => 'value',
              MemberCallKind.getter => 'get',
              MemberCallKind.setter => 'set',
              MemberCallKind.constructor => throw StateError('Static constructor expected'),
            }}'].join(', ')}],',
      );
    }
    result.writeln('];');
    for (final (classId, binding) in plan.classes.indexed) {
      final superclassId = binding.shape.superclassId;
      if (superclassId != null) {
        result.writeln(
          'Object.setPrototypeOf(class$classId.prototype, class$superclassId.prototype);',
        );
      }
      for (final property in binding.shape.prototypeProperties) {
        final method = property.method;
        final getter = property.getter;
        final setter = property.setter;
        result.writeln(
          'Object.defineProperty(class$classId.prototype, ${jsonEncode(property.name)}, {${[
            if (method != null) ...['value: members[${method.classId}][${method.memberIndex}]', 'writable: true'] else ...['get: ${getter == null ? 'undefined' : 'members[${getter.classId}][${getter.memberIndex}]'}', 'set: ${setter == null ? 'undefined' : 'members[${setter.classId}][${setter.memberIndex}]'}'],
            'enumerable: false',
            'configurable: true',
          ].join(', ')}});',
        );
      }
      result.writeln(
        'registerReference($classId, unwrap$classId, wrap$classId);',
      );
    }
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
      call.inputs[i] is ReferenceConversion
          ? '${_optional(p) ? 'd$i ? null : ' : ''}unwrap${(call.inputs[i] as ReferenceConversion).classId}(p$i, ${jsonEncode(call.inputs[i].context)}, ${call.inputs[i].nullable})'
          : 'p$i',
    ],
  ].join(', ');
}

String _output(ValueConversion? output, String invocation) =>
    output is ReferenceConversion
    ? 'wrap${output.classId}($invocation, ${jsonEncode(output.context)})'
    : invocation;

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
