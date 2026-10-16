import '../../lowering/plan.dart';

String emitDeclarations(ModulePlan plan) => [
  '// Generated declarations for the actual Wasm module.',
  '// Use allowArbitraryExtensions for relative .wasm imports.',
  for (final function in plan.functions)
    'export declare function ${function.binding.exportName}(${_parameters(function)}): ${function.output.typescriptType};',
  '',
].join('\n');

String _parameters(FunctionPlan function) {
  final parameters = function.binding.parameters;
  final used = parameters
      .where((p) => p.name != '_')
      .map((p) => p.name)
      .toSet();
  var wildcard = 0;
  return parameters.indexed
      .map((entry) {
        final (index, parameter) = entry;
        var name = parameter.name;
        if (name == '_') {
          do {
            name = 'arg${wildcard++}';
          } while (!used.add(name));
        }
        return '$name: ${function.inputs[index].typescriptType}';
      })
      .join(', ');
}
