import 'dart:convert';

import '../../analysis/reference_views.dart';
import '../../ir/model.dart';
import '../../lowering/plan.dart';
import 'reference_views.dart';
import 'streams.dart';

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
  final streams = plan.calls.any((call) => call.returnsStream);
  final compositeViews = hasCompositeReferenceViews(
    plan.classes.map((c) => c.shape).toList(),
  );
  final result = StringBuffer('''// Generated private callable dependency.
import * as core from './core.wasm';
import {useDefault, readOptions${plan.calls.any((call) => call.returnsFuture) || streams ? ', createPromise, rejectPromise' : ''}${streams ? ', retainPromise' : ''}${plan.resourcePolicies.isNotEmpty ? ', createResourceCall, finishResourceCall, retainResourceReference' : ''}${plan.conversions.any((c) => c is CallbackConversion) ? ', checkCallback' : ''}${plan.conversions.any((c) => c is AbortSignalConversion) ? ', prepareAbortSignal' : ''}} from './boundary.mjs';
''');
  if (streams) result.writeln(streamFacadePolicy);
  if (plan.classes.isNotEmpty) {
    result.writeln("import {registerReference} from './references.mjs';");
    result.writeln('''const wrappers = new WeakMap();
class Receiver {
  constructor(receiver) { return receiver; }
}
class Owner extends Receiver {
  #entry;
  constructor(receiver, entry) { super(receiver); this.#entry = entry; }
  static get(value) {
    if (value === null || (typeof value !== 'object' && typeof value !== 'function')) return undefined;
    return #entry in value ? value.#entry : undefined;
  }
}
const adopt = Symbol();
function unwrap(value, classId, context, nullable) {
  if (value === null && nullable) return null;
  const owner = Owner.get(value);
  if (owner === undefined || (owner.classId !== classId && !memberships[owner.classId].has(classId))) {
    throw new TypeError(context + ': expected a local ' + classNames[classId]);
  }
  return owner.reference;
}
function intern(reference, expectedId, context, pending, receiver, newTarget) {
  const previous = wrappers.get(reference);
  ${compositeViews ? 'let' : 'const'} classId = previous === undefined ? core['napi:class:classify'](reference) : previous.classId;
  if (classId < 0) ${compositeViews ? 'classId = compositeClass(reference, context);' : "throw new TypeError(context + ': no unique most-specific selected class');"}
  if (classId !== expectedId && !memberships[classId].has(expectedId)) {
    throw new TypeError(context + ': expected a local ' + classNames[expectedId]);
  }
  if (previous !== undefined) {
    const wrapper = previous.wrapper.deref();
    if (wrapper !== undefined) return wrapper;
  }
  const wrapper = receiver !== undefined && (newTarget !== constructors[expectedId] || classId === expectedId)
    ? receiver : ${compositeViews ? 'classId < constructors.length ? new constructors[classId](adopt) : Object.create(prototypes[classId])' : 'new constructors[classId](adopt)'};
  const entry = {reference, classId, wrapper: new WeakRef(wrapper)};
  new Owner(wrapper, entry);
  wrappers.set(reference, entry);
  if (previous === undefined && pending !== undefined) {
    pending.add(() => { if (wrappers.get(reference) === entry) wrappers.delete(reference); });
  }
  return wrapper;
}
''');
    if (compositeViews) {
      result.writeln(r'''function compositeClass(reference, context) {
  const views = core['napi:class:views'](reference);
  const key = views.join(',');
  const previous = compositeIds.get(key);
  if (previous !== undefined) return previous;
  const prototype = $napiCompositePrototype(views, context);
  const classId = memberships.length;
  Object.defineProperty(memberships, classId, {value: new Set(views)});
  Object.defineProperty(prototypes, classId, {value: prototype});
  compositeIds.set(key, classId);
  return classId;
}
''');
    }
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
    final resource = plan.needsResourceOperation(function);
    result.writeln('const call$index = (...args) => {');
    if (resource && !function.returnsFuture) _beginResource(result, '  ');
    if (function.returnsFuture) _beginFuture(result, function.output, '  ');
    if (resource) _prepareResource(result, 'null', false, '    ');
    final arguments = _arguments(
      result,
      function,
      function.binding.exportName,
      names[function],
      indent: function.returnsFuture || resource ? '    ' : '  ',
      retainReferences: resource,
    );
    final invocation =
        'core[${jsonEncode(function.coreExportName)}](${[if (function.returnsFuture || resource) 'capability', if (resource) 'operation', if (arguments.isNotEmpty) arguments].join(', ')})';
    if (function.returnsFuture) {
      result.writeln('    $invocation;');
      _endFuture(result, '  ', resource: resource);
    } else {
      result.writeln(
        '${resource ? '    ' : '  '}return ${function.returnsStream ? 'adoptStream($invocation${resource ? ', capability' : ''})' : _output(function.output, invocation)};',
      );
      if (resource) {
        _endResource(result, '  ');
      }
    }
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
      final resource = plan.needsResourceOperation(constructor);
      if (resource) _beginResource(result, '    ');
      final indent = resource ? '      ' : '    ';
      if (resource) _prepareResource(result, 'null', false, indent);
      final arguments = _arguments(
        result,
        constructor,
        binding.binding.exportName,
        names[constructor],
        indent: indent,
        retainReferences: resource,
      );
      result.writeln(
        '${indent}const reference = core[${jsonEncode(constructor.coreExportName)}](${[
          if (resource) ...['capability', 'operation'],
          if (arguments.isNotEmpty) arguments,
        ].join(', ')});',
      );
      result.writeln(
        '${indent}return intern(reference, $index, ${jsonEncode(binding.binding.exportName)}, undefined, this, new.target);',
      );
      if (resource) {
        _endResource(result, '    ');
      }
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
      final resource = plan.needsResourceOperation(member);
      result.writeln('  $declaration {');
      if (resource && !member.returnsFuture) _beginResource(result, '    ');
      if (member.returnsFuture) _beginFuture(result, member.output, '    ');
      final indent = member.returnsFuture || resource ? '      ' : '    ';
      // Module ownership and Dart membership precede options and business calls.
      if (!member.isStatic) {
        result.writeln(
          '${indent}const reference = unwrap$index(this, ${jsonEncode(member.context)}, false);',
        );
      }
      if (resource) {
        _prepareResource(
          result,
          member.isStatic ? 'null' : 'reference',
          member.isCleanup,
          indent,
        );
      }
      if (member.kind == MemberCallKind.setter) {
        result.writeln(
          member.inputs.single is OpaqueConversion
              ? '    const args = arguments.length === 0 ? [] : [value];'
              : '    const args = [value];',
        );
      }
      final arguments = _arguments(
        result,
        member,
        member.context,
        names[member],
        indent: indent,
        retainReferences: resource,
      );
      final invocation =
          'core[${jsonEncode(member.coreExportName)}](${[if (member.returnsFuture || resource) 'capability', if (resource) 'operation', if (!member.isStatic) 'reference', if (arguments.isNotEmpty) arguments].join(', ')})';
      final expression = member.kind == MemberCallKind.constructor
          ? 'wrap$index($invocation, ${jsonEncode(member.context)})'
          : member.returnsStream
          ? 'adoptStream($invocation${resource ? ', capability' : ''})'
          : _output(member.output, invocation);
      if (member.returnsFuture) {
        result.writeln('      $invocation;');
        _endFuture(result, '    ', resource: resource);
        result.writeln('  }');
      } else {
        result.writeln(
          '$indent${member.output == null && !member.returnsStream && member.kind != MemberCallKind.constructor ? '' : 'return '}$expression;',
        );
        if (resource) {
          _endResource(result, '    ');
        }
        result.writeln('  }');
      }
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
    if (compositeViews) {
      result.writeln(
        'const prototypes = constructors.map(constructor => constructor.prototype);\nconst compositeIds = new Map();',
      );
      result.write(
        emitCompositeReferencePrototypes(
          plan.classes.map((c) => c.shape).toList(),
          (ref) => 'members[${ref.classId}][${ref.memberIndex}]',
        ),
      );
    }
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
  bool retainReferences = false,
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
  String reference(int i) =>
      '${_optional(parameters[i]) ? 'd$i ? null : ' : ''}${retainReferences ? 'retainResourceReference(capability, ' : ''}unwrap${(call.inputs[i] as ReferenceConversion).classId}(p$i, ${jsonEncode(call.inputs[i].context)}, ${call.inputs[i].nullable})${retainReferences ? ')' : ''}';
  final directInputs = call.inputs.any(
    (c) => c is CallbackConversion || c is AbortSignalConversion,
  );
  if (directInputs) {
    // Match Native: complete presence and direct-reference admission before
    // binding callbacks, then enter Dart's per-parameter value conversion.
    for (final (i, conversion) in call.inputs.indexed) {
      if (conversion is ReferenceConversion) {
        result.writeln('${indent}const reference$i = ${reference(i)};');
      }
    }
    for (final (i, conversion) in call.inputs.indexed) {
      if (conversion is CallbackConversion) {
        result.writeln(
          '${indent}const callback$i = ${_optional(parameters[i]) ? 'd$i ? null : ' : ''}checkCallback(p$i, ${conversion.nullable}, ${jsonEncode(conversion.context)});',
        );
      } else if (conversion is AbortSignalConversion) {
        result.writeln(
          '${indent}const signal$i = ${_optional(parameters[i]) ? 'd$i ? null : ' : ''}prepareAbortSignal(p$i, ${conversion.nullable}, ${jsonEncode(conversion.context)}, core["napi:signal:notify"]);',
        );
      }
    }
  }
  return [
    for (final (i, p) in parameters.indexed) ...[
      if (_optional(p)) 'd$i ? 1 : 0',
      call.inputs[i] is ReferenceConversion
          ? directInputs
                ? 'reference$i'
                : reference(i)
          : call.inputs[i] is CallbackConversion
          ? 'callback$i'
          : call.inputs[i] is AbortSignalConversion
          ? 'signal$i'
          : 'p$i',
    ],
  ].join(', ');
}

String _output(ValueConversion? output, String invocation) =>
    output is ReferenceConversion
    ? 'wrap${output.classId}($invocation, ${jsonEncode(output.context)})'
    : invocation;

void _beginFuture(StringBuffer result, ValueConversion? output, String indent) {
  final wrap = output is ReferenceConversion
      ? 'value => ${_output(output, 'value')}'
      : '';
  result.writeln('${indent}const capability = createPromise($wrap);');
  result.writeln('${indent}try {');
}

void _endFuture(StringBuffer result, String indent, {bool resource = false}) {
  result.writeln(
    '$indent} catch (error) { rejectPromise(capability, error); }${resource ? ' finally { finishResourceCall(capability); }' : ''}',
  );
  result.writeln('${indent}return capability.promise;');
}

void _beginResource(StringBuffer result, String indent) {
  result.writeln('${indent}const capability = createResourceCall();');
  result.writeln('${indent}try {');
}

void _prepareResource(
  StringBuffer result,
  String reference,
  bool cleanup,
  String indent,
) => result.writeln(
  "${indent}const operation = core['napi:resource:begin'](capability, $reference, ${cleanup ? 1 : 0});",
);

void _endResource(StringBuffer result, String indent) =>
    result.writeln('$indent} finally { finishResourceCall(capability); }');

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
