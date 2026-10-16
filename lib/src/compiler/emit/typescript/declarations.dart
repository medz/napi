import '../../ir/model.dart';
import '../../lowering/plan.dart';
import 'values.dart';

String emitDeclarations(ModulePlan plan) => [
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
    if (function.representation == ExportRepresentation.callableGlobal)
      'export declare const ${function.binding.exportName}: (${emitParameters(function.binding.parameters, function.inputs)}) => ${function.output.typescriptType};'
    else
      'export declare function ${function.binding.exportName}(${emitParameters(function.binding.parameters, function.inputs)}): ${function.output.typescriptType};',
  for (final binding in plan.classes) ...[
    'export declare class ${binding.binding.exportName} {',
    if (binding.constructor case final constructor?)
      '  constructor(${emitParameters(constructor.parameters, constructor.inputs)});'
    else
      '  private constructor();',
    for (final member in binding.members)
      switch (member.kind) {
        MemberCallKind.method =>
          '  ${member.isStatic ? 'static ' : ''}${emitMemberName(member.exportName)}(${emitParameters(member.parameters, member.inputs)}): ${member.output?.typescriptType ?? 'void'};',
        MemberCallKind.getter =>
          '  ${member.isStatic ? 'static ' : ''}get ${emitMemberName(member.exportName)}(): ${member.output?.typescriptType ?? 'void'};',
        MemberCallKind.setter =>
          '  ${member.isStatic ? 'static ' : ''}set ${emitMemberName(member.exportName)}(${emitParameters(member.parameters, member.inputs)});',
        MemberCallKind.constructor =>
          '  static ${emitMemberName(member.exportName)}(${emitParameters(member.parameters, member.inputs)}): ${binding.binding.exportName};',
      },
    '}',
  ],
  '',
].join('\n');

/// TypeScript parses an unquoted constructor method as a class constructor.
String emitMemberName(String name) =>
    name == 'constructor' ? '["constructor"]' : name;

String emitParameters(
  List<ParameterBinding> parameters,
  List<ValueConversion> inputs,
) {
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
    result.add('$name${optional ? '?' : ''}: ${inputs[index].typescriptType}');
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
