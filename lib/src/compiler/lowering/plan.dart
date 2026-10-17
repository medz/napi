export '../ir/model.dart' show ValueDirection;

import 'dart:convert';

import '../../api/annotation.dart' show ClassPolicy;
import '../analysis/result.dart';
import '../analysis/validate.dart';
import '../analysis/validate.dart' as analysis show resourcePolicies;
import '../ir/model.dart';

/// Both forms are actual exports of the consumer's Wasm module.
enum ExportRepresentation {
  /// Fixed arity, nonconstructible; raw JS inputs remain externref until checked.
  nativeFunction,

  /// Immutable externref global holding a JS callable/class; preserves argc/new.
  callableGlobal,
}

enum ScalarKind { boolean, string, integer, doubleValue, bigInteger }

enum BinaryKind { uint8List, byteBuffer }

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

/// A standalone snapshot of the visible bytes, never an implicit shared view.
/// Both backends enforce the same public bound before allocating the snapshot.
final class BinaryConversion extends ValueConversion {
  static const maxByteLength = 0x7fffffff;
  final BinaryKind kind;
  BinaryConversion(DeclaredType super.type, super.context)
    : kind = type.declaration == uint8ListDeclaration
          ? BinaryKind.uint8List
          : type.declaration == byteBufferDeclaration
          ? BinaryKind.byteBuffer
          : throw StateError('Unvalidated binary type');

  @override
  String get dartType =>
      'typed_data.${kind == BinaryKind.uint8List ? 'Uint8List' : 'ByteBuffer'}${nullable ? '?' : ''}';
  @override
  String get jsType => 'object';
  @override
  String get typescriptType =>
      (kind == BinaryKind.uint8List
          ? 'globalThis.Uint8Array<globalThis.ArrayBuffer>'
          : 'globalThis.ArrayBuffer') +
      (nullable ? ' | null' : '');
}

/// An explicit live host byte window; ordinary binary types remain snapshots.
final class SharedBytesConversion extends ValueConversion {
  SharedBytesConversion(super.type, super.context);
  @override
  String get dartType => 'napi.SharedBytes${nullable ? '?' : ''}';
  @override
  String get jsType => 'object';
  @override
  String get typescriptType =>
      'globalThis.Uint8Array<globalThis.ArrayBuffer>${nullable ? ' | null' : ''}';
}

/// An explicit cancellation input. Each backend retains the host signal while
/// its Dart adapter is reachable; accepting it does not cancel ordinary work.
final class AbortSignalConversion extends ValueConversion {
  AbortSignalConversion(super.type, super.context);
  @override
  String get dartType => 'napi.AbortSignal${nullable ? '?' : ''}';
  @override
  String get jsType => 'object';
  @override
  String get typescriptType =>
      'globalThis.AbortSignal${nullable ? ' | null' : ''}';
}

/// A selected logical payload. Backend carriers retain the original JS value.
final class OpaqueConversion extends ValueConversion {
  final DeclarationId parameter;
  OpaqueConversion(TypeParameterType super.type, super.context)
    : parameter = type.declaration;
  @override
  String get dartType => '_NapiHostValue${nullable ? '?' : ''}';
  @override
  String get jsType => 'unknown';
  @override
  String get typescriptType => '${parameter.name}${nullable ? ' | null' : ''}';
}

/// A function input retained while its Dart adapter is reachable. Arguments
/// leave Dart; its synchronous or Future payload result enters Dart.
final class CallbackConversion extends ValueConversion {
  final List<ParameterBinding> parameters;
  final List<ValueConversion> inputs;
  final ValueConversion? output;
  final bool returnsFuture;
  CallbackConversion._(
    FunctionTypeBinding super.type,
    super.context, {
    required Iterable<ValueConversion> inputs,
    required this.output,
  }) : returnsFuture = isFutureType(type.result),
       parameters = type.parameters,
       inputs = List.unmodifiable(inputs);
  @override
  String get dartType {
    final payload = output?.dartType ?? 'void';
    final result = returnsFuture ? 'Future<$payload>' : payload;
    return '$result Function(${inputs.map((c) => c.dartType).join(', ')})${nullable ? '?' : ''}';
  }

  @override
  String get jsType => 'function';
  @override
  String get typescriptType {
    final payload = output?.typescriptType ?? 'void';
    final result = returnsFuture ? 'globalThis.Promise<$payload>' : payload;
    final signature =
        '(${[for (final (i, c) in inputs.indexed) 'arg$i: ${c.typescriptType}'].join(', ')}) => $result';
    return nullable ? '($signature) | null' : signature;
  }

  /// The same JavaScript function has one adapter per conversion contract.
  /// Call-site names and nullable admission do not change an accepted adapter.
  String get signatureKey => jsonEncode([
    returnsFuture,
    inputs.map(_callbackValueSignature).toList(),
    _callbackValueSignature(output),
  ]);
}

Object? _callbackValueSignature(ValueConversion? conversion) =>
    switch (conversion) {
      null => null,
      ScalarConversion(:final kind, :final bigint, :final nullable) => [
        'scalar',
        kind.name,
        bigint,
        nullable,
      ],
      ListConversion(:final element, :final nullable) => [
        'list',
        nullable,
        _callbackValueSignature(element),
      ],
      RecordConversion(:final positional, :final named, :final nullable) => [
        'record',
        nullable,
        positional.map(_callbackValueSignature).toList(),
        for (final name in named.keys.toList()..sort())
          [name, _callbackValueSignature(named[name])],
      ],
      _ => throw StateError('Unsupported callback conversion signature'),
    };

String dartOpaqueTypeArguments(List<TypeParameterBinding> parameters) =>
    parameters.isEmpty
    ? ''
    : '<${parameters.map((_) => '_NapiHostValue').join(', ')}>';

String dartReferenceClassType(ClassBinding binding) =>
    'target.${binding.callPath}${dartOpaqueTypeArguments(binding.typeParameters)}';

/// Prefer a stricter selected specialization without granting its covariant
/// supertypes writable JS views. Unselected subclasses still match by `is`.
String dartReferenceClassTest(
  ClassBinding binding,
  Iterable<ClassBinding> classes, {
  String object = 'object',
}) => [
  '$object is ${dartReferenceClassType(binding)}',
  if (binding.instantiatedType != null)
    for (final other in classes)
      if (other.concreteSupertypes.any(
        (type) => referenceClassMatches(binding, type),
      ))
        '$object is! ${dartReferenceClassType(other)}',
].join(' && ');

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

/// A selected Dart class identity; each backend supplies its own ownership ABI.
final class ReferenceConversion extends ValueConversion {
  final ClassBinding classBinding;
  final int classId;
  final List<BindingType> typeArguments;
  ReferenceConversion(
    DeclaredType super.type,
    super.context, {
    required this.classBinding,
    required this.classId,
  }) : typeArguments = classBinding.instantiatedType == null
           ? type.typeArguments
           : const [];
  @override
  String get dartType =>
      '${dartReferenceClassType(classBinding)}${nullable ? '?' : ''}';
  @override
  String get jsType => 'object';
  @override
  String get typescriptType =>
      '${classBinding.exportName}${typeArguments.isEmpty ? '' : '<${typeArguments.map((t) => (t as TypeParameterType).declaration.name).join(', ')}>'}${nullable ? ' | null' : ''}';
}

final class ListConversion extends ValueConversion {
  final ValueConversion element;
  final bool _qualifiedType;
  ListConversion._(
    super.type,
    super.context,
    this.element, {
    this._qualifiedType = false,
  });
  ListConversion(
    DeclaredType super.type,
    super.context, {
    required bool bigint,
    List<ClassBinding> classes = const [],
  }) : _qualifiedType = false,
       element = conversionFor(
         type.typeArguments.single,
         context,
         bigint: bigint,
         classes: classes,
       );
  @override
  String get dartType => 'List<${element.dartType}>${nullable ? '?' : ''}';
  @override
  String get jsType => 'object';
  @override
  String get typescriptType =>
      '${_qualifiedType ? 'globalThis.' : ''}Array<${element.typescriptType}>${nullable ? ' | null' : ''}';
}

final class MapConversion extends ValueConversion {
  final ValueConversion key;
  final ValueConversion value;
  MapConversion._(super.type, super.context, this.key, this.value);
  MapConversion(
    DeclaredType super.type,
    super.context, {
    required bool bigint,
    List<ClassBinding> classes = const [],
  }) : key = conversionFor(
         type.typeArguments[0],
         context,
         bigint: bigint,
         classes: classes,
       ),
       value = conversionFor(
         type.typeArguments[1],
         context,
         bigint: bigint,
         classes: classes,
       );
  @override
  String get dartType =>
      'Map<${key.dartType}, ${value.dartType}>${nullable ? '?' : ''}';
  @override
  String get jsType => 'object';
  @override
  String get typescriptType =>
      'globalThis.Map<${key.typescriptType}, ${value.typescriptType}>${nullable ? ' | null' : ''}';
}

final class ValueClassField {
  final MemberBinding binding;
  final String name;
  final ParameterBinding? parameter;
  final ValueConversion conversion;
  const ValueClassField(
    this.binding,
    this.name,
    this.conversion, {
    this.parameter,
  });
  bool get optional => parameter?.presence == ParameterPresence.optional;
}

final class ValueClassConversion extends ValueConversion {
  final ValueClassSchema schema;
  final ValueDirection direction;
  final bool bigint;
  late final List<ValueClassField> fields;
  String typescriptName;
  ValueClassConversion._(
    DeclaredType super.type,
    super.context,
    this.schema,
    this.direction,
    this.bigint,
    this.typescriptName,
  );
  ClassBinding get classBinding => schema.binding;
  MemberBinding? get constructor => schema.constructor;
  @override
  String get dartType =>
      'target.${classBinding.callPath}${nullable ? '?' : ''}';
  @override
  String get jsType => 'object';
  @override
  String get typescriptType => '$typescriptName${nullable ? ' | null' : ''}';
}

Iterable<ValueConversion> conversionGraph(
  Iterable<ValueConversion> roots,
) sync* {
  final pending = roots.toList();
  final seen = <ValueConversion>{};
  while (pending.isNotEmpty) {
    final node = pending.removeLast();
    if (!seen.add(node)) continue;
    yield node;
    pending.addAll(switch (node) {
      ListConversion(:final element) => [element],
      MapConversion(:final key, :final value) => [key, value],
      DictionaryConversion(:final value) => [value],
      RecordConversion() => node.fields.values.toList(),
      ValueClassConversion() => [
        for (final field in node.fields) field.conversion,
      ],
      CallbackConversion() => [...node.inputs, ?node.output],
      ScalarConversion() ||
      BinaryConversion() ||
      SharedBytesConversion() ||
      ReferenceConversion() ||
      AbortSignalConversion() ||
      OpaqueConversion() => <ValueConversion>[],
    });
  }
}

bool containsValueClass(ValueConversion value) =>
    conversionGraph([value]).any((c) => c is ValueClassConversion);

final class DictionaryConversion extends ValueConversion {
  final ValueConversion value;
  DictionaryConversion._(super.type, super.context, this.value);
  DictionaryConversion(
    DeclaredType super.type,
    super.context, {
    required bool bigint,
    List<ClassBinding> classes = const [],
  }) : value = conversionFor(
         type.typeArguments.single,
         context,
         bigint: bigint,
         classes: classes,
       );
  @override
  String get dartType =>
      'napi.Dictionary<${value.dartType}>${nullable ? '?' : ''}';
  @override
  String get jsType => 'object';
  @override
  String get typescriptType =>
      '{ [key: string]: ${value.typescriptType} }${nullable ? ' | null' : ''}';
}

bool containsDictionary(ValueConversion value) =>
    conversionGraph([value]).any((c) => c is DictionaryConversion);

final class RecordConversion extends ValueConversion {
  final List<ValueConversion> positional;
  final Map<String, ValueConversion> named;
  final bool _qualifiedType;
  RecordConversion._(
    super.type,
    super.context,
    Iterable<ValueConversion> positional,
    Map<String, ValueConversion> named, {
    this._qualifiedType = false,
  }) : positional = List.unmodifiable(positional),
       named = Map.unmodifiable(named);
  RecordConversion(
    RecordTypeBinding super.type,
    super.context, {
    required bool bigint,
    List<ClassBinding> classes = const [],
  }) : _qualifiedType = false,
       positional = List.unmodifiable([
         for (final field in type.positional)
           conversionFor(field, context, bigint: bigint, classes: classes),
       ]),
       named = Map.unmodifiable({
         for (final entry in type.named.entries)
           entry.key: conversionFor(
             entry.value,
             context,
             bigint: bigint,
             classes: classes,
           ),
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
          ? (_qualifiedType
                ? 'globalThis.Record<globalThis.PropertyKey, never>'
                : 'Record<PropertyKey, never>')
          : '{ ${[for (final e in fields.entries) '${e.key}: ${e.value.typescriptType}'].join('; ')} }') +
      (nullable ? ' | null' : '');
}

ValueConversion conversionFor(
  BindingType type,
  String context, {
  required bool bigint,
  List<ClassBinding> classes = const [],
  List<ValueClassSchema> valueSchemas = const [],
  ValueDirection direction = ValueDirection.output,
  Set<DeclarationId> opaqueParameters = const {},
}) => _ConversionBuilder(
  classes,
  valueSchemas,
  bigint,
  direction,
  opaqueParameters,
).convert(type, context);

final class _ConversionBuilder {
  final List<ClassBinding> classes;
  final List<ValueClassSchema> values;
  final bool bigint;
  final ValueDirection direction;
  final Set<DeclarationId> opaqueParameters;
  final _nodes = <(ClassBinding, TypeNullability), ValueClassConversion>{};
  _ConversionBuilder(
    this.classes,
    this.values,
    this.bigint,
    this.direction,
    this.opaqueParameters,
  );
  bool _shadowsBuiltin(String name) =>
      opaqueParameters.any((p) => p.name == name) ||
      classes.any((binding) => binding.exportName == name);

  ValueConversion convert(BindingType type, String context) {
    if (isSharedBytesType(type)) return SharedBytesConversion(type, context);
    if (isBinaryType(type)) {
      return BinaryConversion(type as DeclaredType, context);
    }
    if (isAbortSignalType(type)) {
      return AbortSignalConversion(type, context);
    }
    if (isOpaqueType(type, opaqueParameters)) {
      return OpaqueConversion(type as TypeParameterType, context);
    }
    if (type is FunctionTypeBinding) {
      final payload = resultPayload(type.result);
      ValueConversion callbackValue(
        BindingType value,
        String path,
        ValueDirection direction,
      ) => conversionFor(
        value,
        path,
        bigint: bigint,
        classes: classes,
        valueSchemas: values,
        direction: direction,
        opaqueParameters: opaqueParameters,
      );
      return CallbackConversion._(
        type,
        context,
        inputs: [
          for (final (i, parameter) in type.parameters.indexed)
            callbackValue(
              parameter.type,
              'callback argument ${i + 1}',
              ValueDirection.output,
            ),
        ],
        output: payload == null
            ? null
            : callbackValue(payload, 'callback result', ValueDirection.input),
      );
    }
    ValueConversion child(BindingType value) => convert(value, context);
    if (type is RecordTypeBinding) {
      return RecordConversion._(
        type,
        context,
        type.positional.map(child),
        type.named.map((key, value) => MapEntry(key, child(value))),
        qualifiedType:
            _shadowsBuiltin('Record') || _shadowsBuiltin('PropertyKey'),
      );
    }
    if (isReferenceType(type, classes, opaqueParameters: opaqueParameters)) {
      final references = classes
          .where((c) => c.classPolicy != ClassPolicy.value)
          .toList();
      final index = references.indexWhere(
        (c) => referenceClassMatches(c, type as DeclaredType),
      );
      return ReferenceConversion(
        type as DeclaredType,
        context,
        classBinding: references[index],
        classId: index,
      );
    }
    if (isValueClassType(type, classes)) {
      final declared = type as DeclaredType;
      final index = values.indexWhere(
        (s) => referenceClassMatches(s.binding, declared),
      );
      if (index < 0) throw StateError('A validated value schema is required.');
      final schema = values[index];
      final key = (schema.binding, declared.nullability);
      if (_nodes[key] case final existing?) return existing;
      if (direction == ValueDirection.input && schema.constructor == null) {
        throw StateError('Output-only value used as input.');
      }
      final node = ValueClassConversion._(
        declared,
        context,
        schema,
        direction,
        bigint,
        '\$value${index}_${direction.name}_${bigint ? 1 : 0}',
      );
      _nodes[key] = node;
      node.fields = List.unmodifiable(
        direction == ValueDirection.input
            ? [
                for (final f in schema.inputFields)
                  ValueClassField(
                    f.field.binding,
                    f.field.name,
                    child(f.parameter.type),
                    parameter: f.parameter,
                  ),
              ]
            : [
                for (final f in schema.outputFields)
                  ValueClassField(f.binding, f.name, child(f.type)),
              ],
      );
      return node;
    }
    if (type is DeclaredType && type.semantics == ValueSemantics.structural) {
      if (type.declaration == dictionaryDeclaration) {
        return DictionaryConversion._(
          type,
          context,
          child(type.typeArguments.single),
        );
      }
      if (type.declaration ==
          DeclarationId(
            Uri.parse('dart:core'),
            'List',
            kind: DeclarationKind.classType,
          )) {
        return ListConversion._(
          type,
          context,
          child(type.typeArguments.single),
          qualifiedType: _shadowsBuiltin('Array'),
        );
      }
      if (type.declaration ==
          DeclarationId(
            Uri.parse('dart:core'),
            'Map',
            kind: DeclarationKind.classType,
          )) {
        return MapConversion._(
          type,
          context,
          child(type.typeArguments[0]),
          child(type.typeArguments[1]),
        );
      }
    }
    return ScalarConversion(type, context, bigint: bigint);
  }
}

/// Ordered private Wasm calls share conversion indices, not declaration kinds.
abstract interface class CallPlan {
  bool get returnsFuture;
  bool get returnsStream;
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
  final bool _hasResources;
  final int _index;
  late final ExportRepresentation representation =
      returnsFuture ||
          returnsStream ||
          inputs.any((c) => c is OpaqueConversion) ||
          inputs.any((c) => c is CallbackConversion) ||
          inputs.any((c) => c is AbortSignalConversion) ||
          output is OpaqueConversion ||
          parameters.any((p) => p.kind != ParameterKind.requiredPositional) ||
          inputs.any((c) => c is ReferenceConversion) ||
          output is ReferenceConversion ||
          (_hasResources &&
              conversionGraph(inputs).any((c) => c is ReferenceConversion))
      ? ExportRepresentation.callableGlobal
      : ExportRepresentation.nativeFunction;
  @override
  final List<ValueConversion> inputs;
  @override
  final ValueConversion? output;
  @override
  late final String coreExportName =
      representation == ExportRepresentation.callableGlobal
      ? 'napi:call:$_index'
      : binding.exportName;
  @override
  final List<int> inputContexts;
  @override
  final int? outputContext;
  @override
  bool get returnsFuture => isFutureType(binding.result);
  @override
  bool get returnsStream => isStreamType(binding.result);
  @override
  List<ParameterBinding> get parameters => binding.parameters;
  FunctionPlan._(
    this.binding,
    int index,
    int firstContext,
    List<ClassBinding> classes,
    List<ValueClassSchema> valueSchemas,
  ) : _index = index,
      _hasResources = classes.any((c) => c.classPolicy == ClassPolicy.resource),
      inputs = List.unmodifiable([
        for (final p in binding.parameters)
          conversionFor(
            p.type,
            '${binding.exportName}.${p.name}',
            bigint: binding.bigint,
            classes: classes,
            valueSchemas: valueSchemas,
            direction: ValueDirection.input,
            opaqueParameters: opaqueParameterIds(binding.typeParameters),
          ),
      ]),
      output = resultPayload(binding.result) == null
          ? null
          : conversionFor(
              resultPayload(binding.result)!,
              '${binding.exportName} result',
              bigint: binding.bigint,
              classes: classes,
              valueSchemas: valueSchemas,
              opaqueParameters: opaqueParameterIds(binding.typeParameters),
            ),
      inputContexts = List.unmodifiable([
        for (var i = 0; i < binding.parameters.length; i++) firstContext + i,
      ]),
      outputContext = resultPayload(binding.result) == null
          ? null
          : firstContext + binding.parameters.length;
}

typedef MemberCallKind = ReferenceMemberKind;

final class MemberCallPlan implements CallPlan {
  final bool isCleanup;
  @override
  final bool returnsFuture;
  @override
  final bool returnsStream;
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
  bool get isStatic => kind == MemberCallKind.constructor || binding.isStatic;
  String get exportName => binding.exportName ?? binding.declaration.name;
  MemberCallPlan._(
    this.owner,
    ReferenceMemberShape member,
    this.coreExportName,
    int firstContext,
    List<ClassBinding> classes,
    List<ValueClassSchema> valueSchemas,
  ) : isCleanup = member.isCleanup,
      returnsFuture = member.returnsFuture,
      returnsStream = member.returnsStream,
      binding = member.binding,
      kind = member.kind,
      parameters = member.parameters,
      context = _memberContext(owner, member),
      inputs = List.unmodifiable([
        for (final parameter in member.parameters)
          conversionFor(
            parameter.type,
            '${_memberContext(owner, member)}.${parameter.name}',
            bigint: false,
            classes: classes,
            valueSchemas: valueSchemas,
            direction: ValueDirection.input,
            opaqueParameters: opaqueParameterIds(owner.typeParameters),
          ),
      ]),
      output = resultPayload(member.result) == null
          ? null
          : conversionFor(
              resultPayload(member.result)!,
              '${_memberContext(owner, member)} result',
              bigint: false,
              classes: classes,
              valueSchemas: valueSchemas,
              opaqueParameters: opaqueParameterIds(owner.typeParameters),
            ),
      inputContexts = List.unmodifiable([
        for (var i = 0; i < member.parameters.length; i++) firstContext + i,
      ]),
      outputContext = resultPayload(member.result) == null
          ? null
          : firstContext + member.parameters.length;
}

String _memberContext(ClassBinding owner, ReferenceMemberShape member) =>
    member.kind == MemberCallKind.constructor &&
        member.binding.declaration.name == 'new'
    ? owner.exportName
    : '${owner.exportName}.${member.binding.exportName ?? member.binding.declaration.name}';

final class ClassPlan {
  final ReferenceClassShape shape;
  final ClassBinding binding;
  final MemberCallPlan? constructor;
  final List<MemberCallPlan> members;
  ClassPlan._(this.shape, this.constructor, Iterable<MemberCallPlan> members)
    : binding = shape.binding,
      members = List.unmodifiable(members);
}

final class ModulePlan {
  /// Import the selected entry surface, not the origin of a re-exported member.
  final Uri source;
  final List<FunctionPlan> functions;
  final List<ClassPlan> classes;
  final List<CallPlan> calls;
  final List<ValueConversion> conversions;
  final List<ClassBinding> allClasses;
  final List<ValueClassSchema> valueSchemas;
  final List<int> referenceClassOrder;
  late final Map<int, int> resourcePolicies = analysis.resourcePolicies(
    classes.map((binding) => binding.shape).toList(),
  );

  bool needsResourceOperation(CallPlan call) =>
      resourcePolicies.isNotEmpty &&
      ((call is MemberCallPlan && !call.isStatic) ||
          conversionGraph(call.inputs).any((c) => c is ReferenceConversion));
  ModulePlan._(
    this.source,
    Iterable<FunctionPlan> functions,
    Iterable<ClassPlan> classes,
    Iterable<CallPlan> calls,
    Iterable<ValueConversion> conversions,
    Iterable<ClassBinding> allClasses,
    Iterable<ValueClassSchema> valueSchemas,
    this.referenceClassOrder,
  ) : functions = List.unmodifiable(functions),
      classes = List.unmodifiable(classes),
      calls = List.unmodifiable(calls),
      conversions = List.unmodifiable(conversions),
      allClasses = List.unmodifiable(allClasses),
      valueSchemas = List.unmodifiable(valueSchemas);
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
    final function = FunctionPlan._(
      binding,
      index,
      conversions.length,
      module.bindings.classes,
      module.valueSchemas,
    );
    functions.add(function);
    add(function);
  }
  for (final (index, shape) in module.classes.indexed) {
    final owner = shape.binding;
    MemberCallPlan member(ReferenceMemberShape shape, String name) {
      final result = MemberCallPlan._(
        owner,
        shape,
        name,
        conversions.length,
        module.bindings.classes,
        module.valueSchemas,
      );
      add(result);
      return result;
    }

    final constructor = shape.constructor == null
        ? null
        : member(shape.constructor!, 'napi:class:$index:new');
    final members = [
      for (final (memberIndex, shape) in shape.members.indexed)
        member(shape, 'napi:class:$index:member:$memberIndex'),
    ];
    classes.add(ClassPlan._(shape, constructor, members));
  }
  return ModulePlan._(
    module.bindings.importUri,
    functions,
    classes,
    calls,
    conversions,
    module.bindings.classes,
    module.valueSchemas,
    referenceClassOrder(module.classes),
  );
}
