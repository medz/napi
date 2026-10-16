import '../analysis/validate.dart';
import '../ir/model.dart';

/// Both forms are actual exports of the consumer's Wasm module.
enum ExportRepresentation {
  /// Fixed arity, nonconstructible; raw JS inputs remain externref until checked.
  nativeFunction,

  /// Immutable externref global holding a JS callable/class; preserves argc/new.
  callableGlobal,
}

enum ScalarKind { boolean, string, integer, doubleValue, bigInteger }

/// One fixed policy drives Dart, JavaScript and TypeScript generation.
final class ScalarConversion {
  final String context;
  final ScalarKind kind;
  final bool nullable;
  final bool bigint;
  ScalarConversion(BindingType type, this.context, {required bool bigint})
    : nullable = type.nullability == TypeNullability.nullable,
      kind = type is SafeIntType
          ? ScalarKind.integer
          : switch ((type as DeclaredType).declaration.name) {
              'bool' => ScalarKind.boolean,
              'String' => ScalarKind.string,
              'double' => ScalarKind.doubleValue,
              'BigInt' => ScalarKind.bigInteger,
              _ => throw StateError('Unvalidated scalar type'),
            },
      bigint = type is SafeIntType && bigint;

  String get dartType =>
      switch (kind) {
        ScalarKind.boolean => 'bool',
        ScalarKind.string => 'String',
        ScalarKind.integer => 'int',
        ScalarKind.doubleValue => 'double',
        ScalarKind.bigInteger => 'BigInt',
      } +
      (nullable ? '?' : '');

  String get jsType => switch (kind) {
    ScalarKind.boolean => 'boolean',
    ScalarKind.string => 'string',
    ScalarKind.integer => bigint ? 'bigint' : 'number',
    ScalarKind.doubleValue => 'number',
    ScalarKind.bigInteger => 'bigint',
  };

  String get typescriptType => '$jsType${nullable ? ' | null' : ''}';
  bool get usesBigInt => kind == ScalarKind.bigInteger || bigint;
}

/// Executable choices are separate from descriptive declaration metadata.
final class FunctionPlan {
  final FunctionBinding binding;
  final ExportRepresentation representation;
  final List<ScalarConversion> inputs;
  final ScalarConversion output;
  FunctionPlan._(this.binding)
    : representation = ExportRepresentation.nativeFunction,
      inputs = List.unmodifiable([
        for (final p in binding.parameters)
          ScalarConversion(
            p.type,
            '${binding.exportName}.${p.name}',
            bigint: binding.bigint,
          ),
      ]),
      output = ScalarConversion(
        binding.result,
        '${binding.exportName} result',
        bigint: binding.bigint,
      );
}

final class ModulePlan {
  /// Import the selected entry surface, not the origin of a re-exported member.
  final Uri source;
  final List<FunctionPlan> functions;
  ModulePlan._(this.source, Iterable<FunctionPlan> functions)
    : functions = List.unmodifiable(functions);
}

/// Descriptive validation alone cannot produce an executable plan. The
/// backend-capability wrapper guarantees that no class or unsupported callable
/// metadata can be silently lost here.
ModulePlan lower(ValidatedModule module) => ModulePlan._(
  module.bindings.source,
  module.bindings.functions.map(FunctionPlan._),
);
