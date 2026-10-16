import '../../ir/model.dart';
import '../../lowering/plan.dart';

String emitDeclarations(ModulePlan plan) => [
  '// Generated declarations for the actual Wasm module.',
  '// Use allowArbitraryExtensions for relative .wasm imports.',
  for (final function in plan.functions)
    if (function.representation == ExportRepresentation.callableGlobal)
      'export declare const ${function.binding.exportName}: (${_parameters(function)}) => ${function.output.typescriptType};'
    else
      'export declare function ${function.binding.exportName}(${_parameters(function)}): ${function.output.typescriptType};',
  '',
].join('\n');

String _parameters(FunctionPlan function) {
  final parameters = function.binding.parameters;
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
    result.add(
      '$name${optional ? '?' : ''}: ${function.inputs[index].typescriptType}',
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
        '${parameter.name}${parameter.kind == ParameterKind.optionalNamed ? '?' : ''}: ${function.inputs[index].typescriptType}${parameter.kind == ParameterKind.optionalNamed ? ' | undefined' : ''}',
    ].join('; ');
    result.add('$name${required ? '' : '?'}: { $properties }');
  }
  return result.join(', ');
}
