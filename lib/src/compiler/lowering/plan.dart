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

/// Specialized conversion shapes shared by each direction's code generator.
sealed class ValueConversion {
  final String context;
  final bool nullable;
  ValueConversion(BindingType type, this.context)
    : nullable = type.nullability == TypeNullability.nullable;

  String get dartType;
  String get jsType;
  String get typescriptType;
}

/// One fixed policy drives Dart, JavaScript and TypeScript scalar generation.
final class ScalarConversion extends ValueConversion {
  final ScalarKind kind;
  final bool bigint;
  ScalarConversion(super.type, super.context, {required bool bigint})
    : kind = type is SafeIntType
          ? ScalarKind.integer
          : switch ((type as DeclaredType).declaration.name) {
              'bool' => ScalarKind.boolean,
              'String' => ScalarKind.string,
              'double' => ScalarKind.doubleValue,
              'BigInt' => ScalarKind.bigInteger,
              _ => throw StateError('Unvalidated scalar type'),
            },
      bigint = type is SafeIntType && bigint;

  @override
  String get dartType =>
      switch (kind) {
        ScalarKind.boolean => 'bool',
        ScalarKind.string => 'String',
        ScalarKind.integer => 'int',
        ScalarKind.doubleValue => 'double',
        ScalarKind.bigInteger => 'BigInt',
      } +
      (nullable ? '?' : '');

  @override
  String get jsType => switch (kind) {
    ScalarKind.boolean => 'boolean',
    ScalarKind.string => 'string',
    ScalarKind.integer => bigint ? 'bigint' : 'number',
    ScalarKind.doubleValue => 'number',
    ScalarKind.bigInteger => 'bigint',
  };

  @override
  String get typescriptType => '$jsType${nullable ? ' | null' : ''}';
  bool get usesBigInt => kind == ScalarKind.bigInteger || bigint;
}

final class ListConversion extends ValueConversion {
  final ValueConversion element;
  ListConversion(DeclaredType super.type, super.context, {required bool bigint})
    : element = conversionFor(
        type.typeArguments.single,
        context,
        bigint: bigint,
      );
  @override
  String get dartType => 'List<${element.dartType}>${nullable ? '?' : ''}';
  @override
  String get jsType => 'object';
  @override
  String get typescriptType =>
      'Array<${element.typescriptType}>${nullable ? ' | null' : ''}';
}

final class RecordConversion extends ValueConversion {
  final List<ValueConversion> positional;
  final Map<String, ValueConversion> named;
  RecordConversion(
    RecordTypeBinding super.type,
    super.context, {
    required bool bigint,
  }) : positional = List.unmodifiable([
         for (final field in type.positional)
           conversionFor(field, context, bigint: bigint),
       ]),
       named = Map.unmodifiable({
         for (final entry in type.named.entries)
           entry.key: conversionFor(entry.value, context, bigint: bigint),
       });
  Map<String, ValueConversion> get fields => {
    for (final (index, field) in positional.indexed) '\$${index + 1}': field,
    ...named,
  };
  @override
  String get dartType {
    final entries = [for (final field in positional) field.dartType];
    if (named.isNotEmpty) {
      entries.add(
        '{${[for (final e in named.entries) '${e.value.dartType} ${e.key}'].join(', ')}}',
      );
    }
    final trailing = positional.length == 1 && named.isEmpty ? ',' : '';
    return '(${entries.join(', ')}$trailing)${nullable ? '?' : ''}';
  }

  @override
  String get jsType => 'object';
  @override
  String get typescriptType =>
      (fields.isEmpty
          ? 'Record<PropertyKey, never>'
          : '{ ${[for (final e in fields.entries) '${e.key}: ${e.value.typescriptType}'].join('; ')} }') +
      (nullable ? ' | null' : '');
}

ValueConversion conversionFor(
  BindingType type,
  String context, {
  required bool bigint,
}) => switch (type) {
  RecordTypeBinding() => RecordConversion(type, context, bigint: bigint),
  DeclaredType(declaration: DeclarationId(name: 'List')) => ListConversion(
    type,
    context,
    bigint: bigint,
  ),
  _ => ScalarConversion(type, context, bigint: bigint),
};

/// Executable choices are separate from descriptive declaration metadata.
final class FunctionPlan {
  final FunctionBinding binding;
  final ExportRepresentation representation;
  final List<ValueConversion> inputs;
  final ValueConversion output;
  final String coreExportName;
  FunctionPlan._(this.binding, int index)
    : representation =
          binding.parameters.any(
            (p) => p.kind != ParameterKind.requiredPositional,
          )
          ? ExportRepresentation.callableGlobal
          : ExportRepresentation.nativeFunction,
      coreExportName =
          binding.parameters.any(
            (p) => p.kind != ParameterKind.requiredPositional,
          )
          ? 'napi:call:$index'
          : binding.exportName,
      inputs = List.unmodifiable([
        for (final p in binding.parameters)
          conversionFor(
            p.type,
            '${binding.exportName}.${p.name}',
            bigint: binding.bigint,
          ),
      ]),
      output = conversionFor(
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
  module.bindings.importUri,
  module.bindings.functions.indexed.map(
    (entry) => FunctionPlan._(entry.$2, entry.$1),
  ),
);
