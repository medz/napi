import '../../analysis/validate.dart';
import '../../ir/model.dart';
import '../../lowering/plan.dart';
import 'values.dart';

String emitDeclarations(ModulePlan plan) => [
  ...emitPromiseResolutionDeclarations(
    plan.calls.where((call) => call.returnsFuture).map((call) => call.output),
  ),
  if (plan.valueSchemas.isNotEmpty)
    emitValueDeclarations(
      plan.allClasses,
      plan.valueSchemas,
      plan.conversions,
      reservedNames: {for (final f in plan.functions) f.binding.exportName},
    ),
  '// Generated declarations for the actual Wasm module.',
  '// Use allowArbitraryExtensions for relative .wasm imports.',
  for (final function in plan.functions)
    ...emitFunctionDeclarations(
      function.binding.exportName,
      function.parameters,
      function.inputs,
      function.output,
      function.binding.typeParameters,
      returnsFuture: function.returnsFuture,
      callable: function.representation == ExportRepresentation.callableGlobal,
    ),
  for (final binding in plan.classes) ...[
    'export declare class ${binding.binding.exportName}${emitTypeParameters(binding.binding.typeParameters, invariant: true)} {',
    if (binding.binding.typeParameters.isNotEmpty)
      '  ${emitOpaquePhantom(binding.binding.typeParameters)}',
    if (binding.constructor case final constructor?)
      for (final parameters in emitParameterVariants(
        constructor.parameters,
        constructor.inputs,
      ))
        '  constructor($parameters);'
    else
      '  private constructor();',
    for (final member in [
      ...binding.members.where((member) => member.isStatic),
      for (final property in binding.shape.prototypeProperties)
        for (final ref in [
          ?property.method,
          ?property.getter,
          ?property.setter,
        ])
          plan.classes[ref.classId].members[ref.memberIndex],
    ])
      for (final parameters in emitParameterVariants(
        member.parameters,
        member.inputs,
      ))
        switch (member.kind) {
          MemberCallKind.method =>
            '  ${member.isStatic ? 'static ' : ''}${emitMemberName(member.exportName)}($parameters): ${emitResult(member.output, returnsFuture: member.returnsFuture)};',
          MemberCallKind.getter =>
            '  ${member.isStatic ? 'static ' : ''}get ${emitMemberName(member.exportName)}(): ${emitResult(member.output, returnsFuture: member.returnsFuture)};',
          MemberCallKind.setter =>
            '  ${member.isStatic ? 'static ' : ''}set ${emitMemberName(member.exportName)}($parameters);',
          MemberCallKind.constructor =>
            '  static ${emitMemberName(member.exportName)}${emitTypeParameters(binding.binding.typeParameters)}($parameters): ${binding.binding.exportName}${emitLogicalTypeArguments(binding.binding.typeParameters)};',
        },
    '}',
    ...emitReferenceInheritance(
      binding.shape,
      plan.classes.map((binding) => binding.shape).toList(),
    ),
  ],
  '',
].join('\n');

String emitTypeParameters(
  List<TypeParameterBinding> parameters, {
  bool invariant = false,
}) => parameters.isEmpty
    ? ''
    : '<${parameters.map((p) => '${invariant ? 'in out ' : ''}${p.declaration.name} = unknown').join(', ')}>';

String emitLogicalTypeArguments(List<TypeParameterBinding> parameters) =>
    parameters.isEmpty
    ? ''
    : '<${parameters.map((p) => p.declaration.name).join(', ')}>';

String emitOpaquePhantom(List<TypeParameterBinding> parameters) {
  final tuple = '[${parameters.map((p) => p.declaration.name).join(', ')}]';
  return 'private readonly \$napiOpaque: (types: $tuple) => $tuple;';
}

Iterable<String> emitFunctionDeclarations(
  String name,
  List<ParameterBinding> parameters,
  List<ValueConversion> inputs,
  ValueConversion? output,
  List<TypeParameterBinding> types, {
  required bool returnsFuture,
  required bool callable,
}) sync* {
  final variants = emitParameterVariants(parameters, inputs).toList();
  final generics = emitTypeParameters(types);
  final result = emitResult(output, returnsFuture: returnsFuture);
  if (callable && variants.length > 1) {
    yield 'export declare const $name: {';
    for (final parameters in variants) {
      yield '  $generics($parameters): $result;';
    }
    yield '};';
  } else {
    for (final parameters in variants) {
      yield callable
          ? 'export declare const $name: $generics($parameters) => $result;'
          : 'export declare function $name$generics($parameters): $result;';
    }
  }
}

/// Opaque optional positions distinguish omission from supplied undefined.
Iterable<String> emitParameterVariants(
  List<ParameterBinding> parameters,
  List<ValueConversion> inputs,
) sync* {
  if (!parameters.any((p) => p.presence == ParameterPresence.opaqueOptional)) {
    yield emitParameters(parameters, inputs);
    return;
  }
  final firstOptional = parameters.indexWhere(
    (p) => p.kind == ParameterKind.optionalPositional,
  );
  for (var length = firstOptional; length <= parameters.length; length++) {
    yield emitParameters(
      parameters.take(length).toList(),
      inputs.take(length).toList(),
      suppliedOptionals: true,
    );
  }
}

/// Promise resolution assimilates a root payload's callable `then` member.
String emitResult(ValueConversion? output, {required bool returnsFuture}) {
  final payload = output?.typescriptType ?? 'void';
  if (!returnsFuture) return payload;
  final resolved = _needsPromiseResolution(output)
      ? '\$napiAwaited<$payload>'
      : payload;
  return 'globalThis.Promise<$resolved>';
}

bool _needsPromiseResolution(ValueConversion? output) =>
    output is OpaqueConversion || output is ReferenceConversion;

/// Unlike TypeScript's Awaited, distribute a nullable or union-valued `then`:
/// its callable branch resolves, while its non-callable branch returns T.
/// Public export and generic identifiers cannot contain `$`.
Iterable<String> emitPromiseResolutionDeclarations(
  Iterable<ValueConversion?> outputs,
) sync* {
  if (outputs.any(_needsPromiseResolution)) {
    yield r'''type $napiAwaited<T> = unknown extends T ? unknown : T extends object
  ? 'then' extends keyof T
    ? T['then'] extends infer F
      ? unknown extends F ? unknown
        : F extends (onfulfilled: infer C, ...args: any[]) => any
          ? C extends (value: infer V, ...args: any[]) => any ? $napiAwaited<V> : never
          : F extends globalThis.Function ? unknown : T
      : never
    : T
  : T;''';
  }
}

/// Merge only the instance type. `class Child extends Base` would incorrectly
/// expose inherited static methods and named constructors.
Iterable<String> emitReferenceInheritance(
  ReferenceClassShape shape,
  List<ReferenceClassShape> classes,
) sync* {
  final parents = shape.memberships.where((id) => id != shape.classId).toList();
  final nearest = parents.where(
    (id) => !parents.any(
      (other) => other != id && classes[other].memberships.contains(id),
    ),
  );
  if (nearest.isNotEmpty) {
    yield 'export interface ${shape.binding.exportName} extends '
        '${nearest.map((id) => classes[id].binding.exportName).join(', ')} {}';
  }
}

/// TypeScript parses an unquoted constructor method as a class constructor.
String emitMemberName(String name) =>
    name == 'constructor' ? '["constructor"]' : name;

String emitParameters(
  List<ParameterBinding> parameters,
  List<ValueConversion> inputs, {
  bool suppliedOptionals = false,
}) {
  final positional = parameters.indexed.where(
    (entry) =>
        entry.$2.kind == ParameterKind.requiredPositional ||
        entry.$2.kind == ParameterKind.optionalPositional,
  );
  final named = parameters.indexed.where(
    (entry) =>
        entry.$2.kind == ParameterKind.requiredNamed ||
        entry.$2.kind == ParameterKind.optionalNamed,
  );
  final used = positional
      .where((entry) => entry.$2.name != '_')
      .map((entry) => entry.$2.name)
      .toSet();
  var wildcard = 0;
  final result = <String>[];
  for (final (index, parameter) in positional) {
    var name = parameter.name;
    if (name == '_') {
      do {
        name = 'arg${wildcard++}';
      } while (!used.add(name));
    }
    final optional = parameter.kind == ParameterKind.optionalPositional;
    final explicitUndefined =
        suppliedOptionals &&
        optional &&
        parameter.presence == ParameterPresence.optional;
    result.add(
      '$name${optional && !suppliedOptionals ? '?' : ''}: ${inputs[index].typescriptType}${explicitUndefined ? ' | undefined' : ''}',
    );
  }
  if (named.isNotEmpty) {
    var name = 'options';
    var suffix = 0;
    while (used.contains(name)) {
      name = 'options${++suffix}';
    }
    final required = named.any(
      (entry) => entry.$2.kind == ParameterKind.requiredNamed,
    );
    final properties = [
      for (final (index, parameter) in named)
        '${parameter.name}${parameter.kind == ParameterKind.optionalNamed ? '?' : ''}: ${inputs[index].typescriptType}${parameter.kind == ParameterKind.optionalNamed ? ' | undefined' : ''}',
    ].join('; ');
    result.add('$name${required ? '' : '?'}: { $properties }');
  }
  return result.join(', ');
}
