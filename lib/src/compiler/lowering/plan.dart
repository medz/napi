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

/// Ordered private Wasm calls share conversion indices, not declaration kinds.
abstract interface class CallPlan {
  List<ParameterBinding> get parameters;
  List<ValueConversion> get inputs;
  ValueConversion? get output;
  String get coreExportName;
  List<int> get inputContexts;
  int? get outputContext;
}

/// Executable choices are separate from descriptive declaration metadata.
final class FunctionPlan implements CallPlan {
  final FunctionBinding binding;
  final ExportRepresentation representation;
  @override
  final List<ValueConversion> inputs;
  @override
  final ValueConversion output;
  @override
  final String coreExportName;
  @override
  final List<int> inputContexts;
  @override
  final int outputContext;
  @override
  List<ParameterBinding> get parameters => binding.parameters;
  FunctionPlan._(this.binding, int index, int firstContext)
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
      ),
      inputContexts = List.unmodifiable([
        for (var i = 0; i < binding.parameters.length; i++) firstContext + i,
      ]),
      outputContext = firstContext + binding.parameters.length;
}

typedef MemberCallKind = ReferenceMemberKind;

final class MemberCallPlan implements CallPlan {
  final ClassBinding owner;
  final MemberBinding binding;
  final MemberCallKind kind;
  final String context;
  @override
  final List<ParameterBinding> parameters;
  @override
  final List<ValueConversion> inputs;
  @override
  final ValueConversion? output;
  @override
  final String coreExportName;
  @override
  final List<int> inputContexts;
  @override
  final int? outputContext;
  bool get isStatic => binding.isStatic;
  String get exportName => binding.exportName ?? binding.declaration.name;
  MemberCallPlan._(
    this.owner,
    ReferenceMemberShape member,
    this.coreExportName,
    int firstContext,
  ) : binding = member.binding,
      kind = member.kind,
      parameters = member.parameters,
      context = _memberContext(owner, member),
      inputs = List.unmodifiable([
        for (final parameter in member.parameters)
          conversionFor(
            parameter.type,
            '${_memberContext(owner, member)}.${parameter.name}',
            bigint: false,
          ),
      ]),
      output = member.result == null
          ? null
          : conversionFor(
              member.result!,
              '${_memberContext(owner, member)} result',
              bigint: false,
            ),
      inputContexts = List.unmodifiable([
        for (var i = 0; i < member.parameters.length; i++) firstContext + i,
      ]),
      outputContext = member.result == null
          ? null
          : firstContext + member.parameters.length;
}

String _memberContext(ClassBinding owner, ReferenceMemberShape member) =>
    member.kind == MemberCallKind.constructor
    ? owner.exportName
    : '${owner.exportName}.${member.binding.exportName ?? member.binding.declaration.name}';

final class ClassPlan {
  final ClassBinding binding;
  final MemberCallPlan constructor;
  final List<MemberCallPlan> members;
  ClassPlan._(this.binding, this.constructor, Iterable<MemberCallPlan> members)
    : members = List.unmodifiable(members);
}

final class ModulePlan {
  /// Import the selected entry surface, not the origin of a re-exported member.
  final Uri source;
  final List<FunctionPlan> functions;
  final List<ClassPlan> classes;
  final List<CallPlan> calls;
  final List<ValueConversion> conversions;
  ModulePlan._(
    this.source,
    Iterable<FunctionPlan> functions,
    Iterable<ClassPlan> classes,
    Iterable<CallPlan> calls,
    Iterable<ValueConversion> conversions,
  ) : functions = List.unmodifiable(functions),
      classes = List.unmodifiable(classes),
      calls = List.unmodifiable(calls),
      conversions = List.unmodifiable(conversions);
}

/// Descriptive validation alone cannot produce an executable plan. The
/// backend-capability wrapper guarantees that no class or unsupported callable
/// metadata can be silently lost here.
ModulePlan lower(ValidatedModule module) {
  final functions = <FunctionPlan>[];
  final classes = <ClassPlan>[];
  final calls = <CallPlan>[];
  final conversions = <ValueConversion>[];
  void add(CallPlan call) {
    calls.add(call);
    conversions.addAll(call.inputs);
    if (call.output case final output?) conversions.add(output);
  }

  for (final (index, binding) in module.bindings.functions.indexed) {
    final function = FunctionPlan._(binding, index, conversions.length);
    functions.add(function);
    add(function);
  }
  for (final (index, shape) in module.classes.indexed) {
    final owner = shape.binding;
    MemberCallPlan member(ReferenceMemberShape shape, String name) {
      final result = MemberCallPlan._(owner, shape, name, conversions.length);
      add(result);
      return result;
    }

    final constructor = member(shape.constructor, 'napi:class:$index:new');
    final members = [
      for (final (memberIndex, shape) in shape.members.indexed)
        member(shape, 'napi:class:$index:member:$memberIndex'),
    ];
    classes.add(ClassPlan._(shape.binding, constructor, members));
  }
  return ModulePlan._(
    module.bindings.importUri,
    functions,
    classes,
    calls,
    conversions,
  );
}
