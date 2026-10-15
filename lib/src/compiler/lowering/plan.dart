import '../analysis/validate.dart';
import '../ir/model.dart';

/// Both forms are actual exports of the consumer's Wasm module.
enum ExportRepresentation {
  /// Fixed arity, nonconstructible; raw JS inputs remain externref until checked.
  nativeFunction,

  /// Immutable externref global holding a JS callable/class; preserves argc/new.
  callableGlobal,
}

final class SafeIntConversion {
  final String context;
  const SafeIntConversion(this.context);
}

/// Executable choices are separate from descriptive declaration metadata.
final class FunctionPlan {
  final FunctionBinding binding;
  final ExportRepresentation representation;
  final List<SafeIntConversion> inputs;
  final SafeIntConversion output;
  FunctionPlan._(this.binding)
    : representation = ExportRepresentation.nativeFunction,
      inputs = List.unmodifiable([
        for (final p in binding.parameters)
          SafeIntConversion('${binding.exportName}.${p.name}'),
      ]),
      output = SafeIntConversion('${binding.exportName} result');
}

final class ModulePlan {
  final Uri source;
  final List<FunctionPlan> functions;
  ModulePlan._(this.source, Iterable<FunctionPlan> functions)
    : functions = List.unmodifiable(functions);
}

ModulePlan lower(ValidatedModule module) => ModulePlan._(
  module.bindings.source,
  module.bindings.functions.map(FunctionPlan._),
);
