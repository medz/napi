import '../../lowering/plan.dart';

String emitDeclarations(ModulePlan plan) => [
  '// Generated declarations for the actual Wasm module.',
  '// Use allowArbitraryExtensions for relative .wasm imports.',
  for (final function in plan.functions)
    'export declare function ${function.binding.exportName}(${function.binding.parameters.map((p) => '${p.name}: number').join(', ')}): number;',
  '',
].join('\n');
