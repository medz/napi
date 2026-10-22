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

/// An explicit retained host container. Ordinary List/Map remain snapshots.
final class JsCollectionConversion extends ValueConversion {
  final bool isMap;
  final ValueConversion? key;
  final ValueConversion value;
  final ValueConversion? inputKey;
  final ValueConversion inputValue;
  JsCollectionConversion._(
    DeclaredType super.type,
    super.context, {
    required this.key,
    required this.value,
    required this.inputKey,
    required this.inputValue,
  }) : isMap = type.declaration == jsMapDeclaration;
  static Object _signature(ValueConversion value) => switch (value) {
    ScalarConversion() => [value.kind.name, value.bigint, value.nullable],
    OpaqueConversion() => ['opaque', value.nullable],
    ReferenceConversion() => ['reference', value.classId, value.nullable],
    BinaryConversion() => ['binary', value.kind.name, value.nullable],
    SharedBytesConversion() => ['sharedBytes', value.nullable],
    CallbackConversion() => [
      'function',
      value.wireSignatureKey,
      value.nullable,
    ],
    ValueClassConversion() => [
      'value',
      value.schemaId,
      value.bigint,
      value.nullable,
    ],
    ListConversion() => ['list', value.nullable, _signature(value.element)],
    MapConversion() => [
      'map',
      value.nullable,
      _signature(value.key),
      _signature(value.value),
    ],
    DictionaryConversion() => [
      'dictionary',
      value.nullable,
      _signature(value.value),
    ],
    RecordConversion() => [
      'record',
      value.nullable,
      value.positional.map(_signature).toList(),
      for (final name in value.named.keys.toList()..sort())
        [name, _signature(value.named[name]!)],
    ],
    JsCollectionConversion() => [
      'collection',
      value.nullable,
      _collectionSignature(value),
    ],
    _ => throw StateError('Unsupported JS collection element'),
  };
  static Object _collectionSignature(JsCollectionConversion value) => [
    value.isMap,
    if (value.key case final key?) _signature(key),
    _signature(value.value),
  ];
  String get signatureKey => jsonEncode(_collectionSignature(this));
  @override
  String get dartType =>
      'napi.${isMap ? 'JsMap<${key!.dartType}, ${value.dartType}>' : 'JsArray<${value.dartType}>'}${nullable ? '?' : ''}';
  @override
  String get jsType => 'object';
  static String _storedType(ValueConversion input, ValueConversion output) {
    if (!conversionDependencies([input, output]).any(
      (value) => value is ValueClassConversion || value is CallbackConversion,
    )) {
      return output.typescriptType;
    }
    final read = input.typescriptType;
    final write = output.typescriptType;
    if (read == write || read == 'never' || read == 'null' && output.nullable) {
      return write;
    }
    return input is CallbackConversion || output is CallbackConversion
        ? '($read) | ($write)'
        : '$read | $write';
  }

  @override
  String get typescriptType =>
      'globalThis.${isMap ? 'Map<${_storedType(inputKey!, key!)}, ${_storedType(inputValue, value)}>' : 'Array<${_storedType(inputValue, value)}>'}${nullable ? ' | null' : ''}';
}

/// Lazy references may expose a resource through an ordinary selected view.
bool containsJsCollectionReference(
  ValueConversion conversion, {
  List<ClassBinding> classes = const [],
}) =>
    conversion is JsCollectionConversion &&
    (conversionDependencies(
          [conversion],
          includeFunctions: false,
        ).any((element) => element is ReferenceConversion) ||
        hasDefaultResources(const [], [conversion], classes));

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

/// A typed function converted as a JavaScript callback or a Dart function facade.
final class CallbackConversion extends ValueConversion {
  final ValueDirection direction;
  final List<ParameterBinding> parameters;
  final List<ValueConversion> inputs;
  final ValueConversion? output;
  final bool returnsFuture;
  final bool returnsStream;
  CallbackConversion._(
    FunctionTypeBinding super.type,
    super.context, {
    required this.direction,
    required Iterable<ValueConversion> inputs,
    required this.output,
  }) : returnsFuture = isFutureType(type.result),
       returnsStream = isStreamType(type.result),
       parameters = type.parameters,
       inputs = List.unmodifiable(inputs);

  bool get hasParameterShape => parameters.any(
    (parameter) => parameter.kind != ParameterKind.requiredPositional,
  );
  bool isOptionalParameter(int index) =>
      parameters[index].kind == ParameterKind.optionalPositional ||
      parameters[index].kind == ParameterKind.optionalNamed;
  bool isNamedParameter(int index) =>
      parameters[index].kind == ParameterKind.requiredNamed ||
      parameters[index].kind == ParameterKind.optionalNamed;

  String _dartParameters({bool adapter = false}) {
    final positional = <String>[];
    final optional = <String>[];
    final named = <String>[];
    for (final (index, parameter) in parameters.indexed) {
      final type = adapter && isOptionalParameter(index)
          ? 'Object?'
          : inputs[index].dartType;
      final fallback = adapter && isOptionalParameter(index)
          ? ' = _napiCallbackAbsent'
          : '';
      switch (parameter.kind) {
        case ParameterKind.requiredPositional:
          positional.add('$type${adapter ? ' _p$index' : ''}');
        case ParameterKind.optionalPositional:
          optional.add('$type${adapter ? ' _p$index$fallback' : ''}');
        case ParameterKind.requiredNamed:
          named.add('required $type ${parameter.name}');
        case ParameterKind.optionalNamed:
          named.add('$type ${parameter.name}$fallback');
      }
    }
    return [
      ...positional,
      if (optional.isNotEmpty) '[${optional.join(', ')}]',
      if (named.isNotEmpty) '{${named.join(', ')}}',
    ].join(', ');
  }

  /// Optional adapters accept a private sentinel through contravariant inputs.
  /// A separate invocation body keeps named parameters out of generated scopes.
  String get adapterParameters => _dartParameters(adapter: true);
  String get invocationParameters => [
    for (final (index, conversion) in inputs.indexed)
      '${isOptionalParameter(index) ? 'Object?' : conversion.dartType} c$index',
  ].join(', ');
  String get adapterArguments => [
    for (final (index, parameter) in parameters.indexed)
      isNamedParameter(index) ? parameter.name : '_p$index',
  ].join(', ');
  String argumentValue(int index) => isOptionalParameter(index)
      ? '(c$index as ${inputs[index].dartType})'
      : 'c$index';
  String argumentPresent(int index) => isOptionalParameter(index)
      ? '!identical(c$index, _napiCallbackAbsent)'
      : 'true';

  @override
  String get dartType {
    final payload = output?.dartType ?? 'void';
    final result = returnsFuture
        ? 'Future<$payload>'
        : returnsStream
        ? 'Stream<$payload>'
        : payload;
    return '$result Function(${_dartParameters()})${nullable ? '?' : ''}';
  }

  @override
  String get jsType => 'function';
  @override
  String get typescriptType {
    final payload = output?.typescriptType ?? 'void';
    final result = returnsFuture
        ? 'globalThis.Promise<$payload>'
        : returnsStream
        ? 'globalThis.AsyncIterableIterator<$payload, undefined, undefined>'
        : payload;
    final positional = <String>[];
    final named = <String>[];
    var requiredOptions = false;
    for (final (index, parameter) in parameters.indexed) {
      final optional = isOptionalParameter(index) ? '?' : '';
      final type = inputs[index].typescriptType;
      if (isNamedParameter(index)) {
        named.add('${jsonEncode(parameter.name)}$optional: $type');
        requiredOptions |= parameter.kind == ParameterKind.requiredNamed;
      } else {
        positional.add('arg$index$optional: $type');
      }
    }
    if (named.isNotEmpty) {
      positional.add(
        'options${requiredOptions ? '' : '?'}: { ${named.join('; ')} }',
      );
    }
    final signature = '(${positional.join(', ')}) => $result';
    return nullable ? '($signature) | null' : signature;
  }

  /// The same JavaScript function has one adapter per conversion contract.
  /// Positional names and nullable admission do not change an accepted adapter.
  String get signatureKey => _signature(false);
  String get wireSignatureKey => _signature(true);

  String _signature(bool wire) {
    if (!hasParameterShape) {
      return jsonEncode([
        returnsStream ? 'stream' : returnsFuture,
        inputs
            .map((value) => _callbackValueSignature(value, wire: wire))
            .toList(),
        _callbackValueSignature(output, wire: wire),
      ]);
    }
    final ordered = parameters.indexed.toList()
      ..sort((a, b) {
        final aNamed = isNamedParameter(a.$1);
        final bNamed = isNamedParameter(b.$1);
        if (aNamed != bNamed) return aNamed ? 1 : -1;
        return aNamed ? a.$2.name.compareTo(b.$2.name) : a.$1.compareTo(b.$1);
      });
    return jsonEncode([
      returnsStream ? 'stream' : returnsFuture,
      [
        'parameters',
        for (final (index, parameter) in ordered)
          [
            parameter.kind.name,
            if (isNamedParameter(index)) parameter.name,
            _callbackValueSignature(inputs[index], wire: wire),
          ],
      ],
      _callbackValueSignature(output, wire: wire),
    ]);
  }
}

Object? _callbackValueSignature(
  ValueConversion? conversion, {
  bool wire = false,
}) => switch (conversion) {
  null => null,
  ScalarConversion(:final kind, :final bigint, :final nullable) => [
    'scalar',
    kind.name,
    bigint,
    nullable,
  ],
  BinaryConversion(:final kind, :final nullable) => [
    'binary',
    kind.name,
    nullable,
  ],
  SharedBytesConversion(:final nullable) => ['sharedBytes', nullable],
  OpaqueConversion(:final nullable) => ['opaque', nullable],
  ReferenceConversion(:final classId, :final nullable) => [
    'reference',
    classId,
    nullable,
  ],
  ValueClassConversion() => [
    'value',
    conversion.schemaId,
    if (wire) conversion.direction.name,
    conversion.bigint,
    conversion.nullable,
  ],
  CallbackConversion() => [
    'function',
    wire ? conversion.wireSignatureKey : conversion.signatureKey,
    conversion.nullable,
  ],
  JsCollectionConversion() => [
    'jsCollection',
    conversion.nullable,
    conversion.signatureKey,
  ],
  ListConversion(:final element, :final nullable) => [
    'list',
    nullable,
    _callbackValueSignature(element, wire: wire),
  ],
  MapConversion(:final key, :final value, :final nullable) => [
    'map',
    nullable,
    _callbackValueSignature(key, wire: wire),
    _callbackValueSignature(value, wire: wire),
  ],
  DictionaryConversion(:final value, :final nullable) => [
    'dictionary',
    nullable,
    _callbackValueSignature(value, wire: wire),
  ],
  RecordConversion(:final positional, :final named, :final nullable) => [
    'record',
    nullable,
    positional
        .map((value) => _callbackValueSignature(value, wire: wire))
        .toList(),
    for (final name in named.keys.toList()..sort())
      [name, _callbackValueSignature(named[name], wire: wire)],
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
/// Emit each dependent specialization check once for a classification scope.
/// Ordinary declarations keep their inline tests and unchanged generated code.
final class DartReferenceClassTests {
  final List<ClassBinding> _classes;
  final String object;
  final _tests = <ClassBinding, String>{};
  final _declarations = StringBuffer();

  DartReferenceClassTests(
    Iterable<ClassBinding> classes, {
    this.object = 'object',
    Iterable<ClassBinding>? tested,
  }) : _classes = classes.toList() {
    final dependent = _classes.any((binding) => _children(binding).isNotEmpty);
    String generate(ClassBinding binding) => _tests.putIfAbsent(binding, () {
      final condition = [
        '$object is ${dartReferenceClassType(binding)}',
        if (binding.instantiatedType != null)
          for (final other in _classes)
            if (other.concreteSupertypes.any(
              (type) => referenceClassMatches(binding, type),
            ))
              dependent
                  ? '!${generate(other)}'
                  : '$object is! ${dartReferenceClassType(other)}',
        // Both covariance and ancestry exclusions use effective selected views.
        // A raw narrower type may itself be suppressed by a selected descendant.
        for (final other in _children(binding)) '!${generate(other)}',
      ].join(' && ');
      if (!dependent) return condition;
      final name = '_napiClass${_classes.indexOf(binding)}';
      _declarations.writeln('  final $name = $condition;');
      return name;
    });
    for (final binding in tested ?? _classes) {
      generate(binding);
    }
  }

  Iterable<ClassBinding> _children(ClassBinding binding) =>
      binding.instantiatedType == null
      ? const []
      : _classes.where(
          (other) => other.allSupertypes.any(
            (type) =>
                type.declaration == binding.declaration &&
                !referenceClassMatches(binding, type),
          ),
        );

  String get declarations => _declarations.toString();
  String test(ClassBinding binding) => _tests[binding]!;
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
  }) : typeArguments = referenceTypeArguments(classBinding, type)!;
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
  final ValueDirection direction;
  final bool _qualifiedType;
  ListConversion._(
    super.type,
    super.context,
    this.element, {
    required this.direction,
    this._qualifiedType = false,
  });
  ListConversion(
    DeclaredType super.type,
    super.context, {
    required bool bigint,
    List<ClassBinding> classes = const [],
    this.direction = ValueDirection.output,
  }) : _qualifiedType = false,
       element = conversionFor(
         type.typeArguments.single,
         context,
         bigint: bigint,
         classes: classes,
         direction: direction,
       );
  @override
  String get dartType => 'List<${element.dartType}>${nullable ? '?' : ''}';
  @override
  String get jsType => 'object';
  @override
  String get typescriptType =>
      '${_qualifiedType ? 'globalThis.' : ''}${direction == ValueDirection.input ? 'ReadonlyArray' : 'Array'}<${element.typescriptType}>${nullable ? ' | null' : ''}';
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
  final MemberBinding? binding;
  final String name;
  final ParameterBinding? parameter;
  final ValueConversion conversion;
  const ValueClassField(
    this.binding,
    this.name,
    this.conversion, {
    this.parameter,
  });
  String? get documentation =>
      binding?.documentation ?? parameter?.documentation;
  bool get optional =>
      parameter?.presence == ParameterPresence.optional || opaqueOptional;
  bool get opaqueOptional =>
      parameter?.presence == ParameterPresence.opaqueOptional;
}

final class ValueClassConversion extends ValueConversion {
  final ValueClassSchema schema;
  final int schemaId;
  final ValueDirection direction;
  final bool bigint;
  final List<BindingType> typeArguments;
  late final List<ValueClassField> fields;
  String typescriptName;
  ValueClassConversion._(
    DeclaredType super.type,
    super.context,
    this.schema,
    this.schemaId,
    this.direction,
    this.bigint,
    this.typescriptName,
  ) : typeArguments = referenceTypeArguments(schema.binding, type)!;
  ClassBinding get classBinding => schema.binding;
  MemberBinding? get constructor => schema.constructor;
  String get dartConstructorType => dartReferenceClassType(classBinding);
  @override
  String get dartType => '$dartConstructorType${nullable ? '?' : ''}';
  @override
  String get jsType => 'object';
  @override
  String get typescriptType =>
      direction == ValueDirection.input && constructor == null
      ? nullable
            ? 'null'
            : 'never'
      : '$typescriptName${typeArguments.isEmpty ? '' : '<${typeArguments.map((argument) => (argument as TypeParameterType).declaration.name).join(', ')}>'}${nullable ? ' | null' : ''}';
}

Iterable<ValueConversion> conversionGraph(
  Iterable<ValueConversion> roots, {
  bool includeFunctions = true,
}) sync* {
  final pending = <ValueConversion>[...roots];
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
      CallbackConversion() =>
        includeFunctions ? [...node.inputs, ?node.output] : <ValueConversion>[],
      ScalarConversion() ||
      BinaryConversion() ||
      SharedBytesConversion() ||
      JsCollectionConversion() ||
      ReferenceConversion() ||
      AbortSignalConversion() ||
      OpaqueConversion() => <ValueConversion>[],
    });
  }
}

/// Runtime dependencies also include lazy collection element policies.
Iterable<ValueConversion> conversionDependencies(
  Iterable<ValueConversion> roots, {
  bool includeFunctions = true,
}) sync* {
  final pending = conversionGraph(
    roots,
    includeFunctions: includeFunctions,
  ).toList();
  final seen = <ValueConversion>{};
  while (pending.isNotEmpty) {
    final node = pending.removeLast();
    if (!seen.add(node)) continue;
    yield node;
    if (node is JsCollectionConversion) {
      pending.addAll(
        conversionGraph([
          ?node.key,
          node.value,
          ?node.inputKey,
          node.inputValue,
        ], includeFunctions: includeFunctions),
      );
    }
  }
}

/// Reference leaves of built-in default containers; value fields stay separate.
bool containsDefaultReference(ValueConversion conversion) =>
    switch (conversion) {
      ReferenceConversion() => true,
      ListConversion(:final element) => containsDefaultReference(element),
      MapConversion(:final key, :final value) =>
        containsDefaultReference(key) || containsDefaultReference(value),
      DictionaryConversion(:final value) => containsDefaultReference(value),
      RecordConversion() => conversion.fields.values.any(
        containsDefaultReference,
      ),
      _ => false,
    };

bool hasDefaultResources(
  Iterable<ParameterBinding> parameters,
  Iterable<ValueConversion> conversions,
  List<ClassBinding> classes,
) {
  bool resource(ParameterBinding parameter) =>
      defaultResourceObjects(parameter, classes).isNotEmpty;
  return parameters.any(resource) ||
      conversionDependencies(conversions).whereType<ValueClassConversion>().any(
        (value) => value.fields.any(
          (field) => field.parameter != null && resource(field.parameter!),
        ),
      );
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
  final RecordTypeBinding type;
  final List<ValueConversion> positional;
  final Map<String, ValueConversion> named;
  final bool _qualifiedType;
  RecordConversion._(
    this.type,
    String context,
    Iterable<ValueConversion> positional,
    Map<String, ValueConversion> named, {
    this._qualifiedType = false,
  }) : positional = List.unmodifiable(positional),
       named = Map.unmodifiable(named),
       super(type, context);
  RecordConversion(
    this.type,
    String context, {
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
       }),
       super(type, context);
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
  final _nodes =
      <
        (ClassBinding, TypeNullability, ValueDirection),
        List<ValueClassConversion>
      >{};
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

  ValueConversion convert(
    BindingType type,
    String context, {
    ValueDirection? valueDirection,
    bool lazy = false,
  }) {
    final direction = valueDirection ?? this.direction;
    if (isJsCollectionType(type)) {
      final declared = type as DeclaredType;
      final map = declared.declaration == jsMapDeclaration;
      ValueConversion element(
        BindingType type,
        String path,
        ValueDirection direction,
      ) => convert(type, path, valueDirection: direction, lazy: true);
      return JsCollectionConversion._(
        declared,
        context,
        key: map
            ? element(
                declared.typeArguments.first,
                'JsMap key',
                ValueDirection.output,
              )
            : null,
        value: element(
          declared.typeArguments.last,
          map ? 'JsMap value' : 'JsArray value',
          ValueDirection.output,
        ),
        inputKey: map
            ? element(
                declared.typeArguments.first,
                'JsMap key',
                ValueDirection.input,
              )
            : null,
        inputValue: element(
          declared.typeArguments.last,
          map ? 'JsMap value' : 'JsArray value',
          ValueDirection.input,
        ),
      );
    }
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
      ) => convert(value, path, valueDirection: direction, lazy: lazy);
      return CallbackConversion._(
        type,
        context,
        direction: direction,
        inputs: [
          for (final (i, parameter) in type.parameters.indexed)
            callbackValue(
              parameter.type,
              'callback argument ${i + 1}',
              direction == ValueDirection.input
                  ? ValueDirection.output
                  : ValueDirection.input,
            ),
        ],
        output: payload == null
            ? null
            : callbackValue(payload, 'callback result', direction),
      );
    }
    ValueConversion child(BindingType value) =>
        convert(value, context, valueDirection: direction, lazy: lazy);
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
      final key = (schema.binding, declared.nullability, direction);
      final arguments = referenceTypeArguments(schema.binding, declared)!;
      if (!lazy &&
          direction == ValueDirection.input &&
          schema.constructor == null) {
        throw StateError('Output-only value used as input.');
      }
      final instances = _nodes.putIfAbsent(key, () => []);
      for (final existing in instances) {
        if (existing.typeArguments.length == arguments.length &&
            existing.typeArguments.indexed.every(
              (entry) =>
                  (entry.$2 as TypeParameterType).declaration ==
                  (arguments[entry.$1] as TypeParameterType).declaration,
            )) {
          return existing;
        }
      }
      final node = ValueClassConversion._(
        declared,
        context,
        schema,
        index,
        direction,
        bigint,
        '\$value${index}_${direction.name}_${bigint ? 1 : 0}',
      );
      instances.add(node);
      final projection = valueClassParameterProjection(
        schema.binding,
        declared,
      );
      BindingType project(BindingType type) =>
          projection.isEmpty ? type : projectOpaqueType(type, projection);
      node.fields = List.unmodifiable(
        direction == ValueDirection.input
            ? [
                for (final f in schema.inputFields)
                  ValueClassField(
                    f.field?.binding,
                    f.name,
                    child(project(f.parameter.type)),
                    parameter: projection.isEmpty
                        ? f.parameter
                        : projectOpaqueParameter(f.parameter, projection),
                  ),
              ]
            : [
                for (final f in schema.outputFields)
                  ValueClassField(f.binding, f.name, child(project(f.type))),
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
          direction: direction,
          qualifiedType: _shadowsBuiltin(
            direction == ValueDirection.input ? 'ReadonlyArray' : 'Array',
          ),
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
  late final bool _hasScopedResourceAccess;
  final int _index;
  late final ExportRepresentation representation =
      returnsFuture ||
          returnsStream ||
          _hasScopedResourceAccess ||
          inputs.any((c) => c is OpaqueConversion) ||
          conversionDependencies([...inputs, ?output])
              .any((c) => c is CallbackConversion) ||
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
            opaqueParameters: opaqueParameterIds(
              referenceCallTypeParameters(owner, member.binding),
            ),
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
              opaqueParameters: opaqueParameterIds(
                referenceCallTypeParameters(owner, member.binding),
              ),
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

/// One private call entry for every exported function value contract.
final class FunctionValueCallPlan implements CallPlan {
  final CallbackConversion conversion;
  final int contractId;
  final String context = 'function';
  @override
  final List<ParameterBinding> parameters;
  @override
  final List<int> inputContexts;
  @override
  final int? outputContext;
  @override
  List<ValueConversion> get inputs => conversion.inputs;
  @override
  ValueConversion? get output => conversion.output;
  @override
  bool get returnsFuture => conversion.returnsFuture;
  @override
  bool get returnsStream => conversion.returnsStream;
  @override
  String get coreExportName => 'napi:function:$contractId';

  FunctionValueCallPlan._(this.conversion, this.contractId, int firstContext)
    : parameters = [
        for (final (index, parameter) in conversion.parameters.indexed)
          ParameterBinding(
            parameter.name,
            parameter.type,
            defaultObjects: parameter.defaultObjects,
            kind: parameter.kind,
            presence: conversion.inputs[index] is OpaqueConversion
                ? conversion.isOptionalParameter(index)
                      ? ParameterPresence.opaqueOptional
                      : ParameterPresence.opaqueRequired
                : conversion.isOptionalParameter(index)
                ? ParameterPresence.optional
                : ParameterPresence.required,
            source: parameter.source,
          ),
      ],
      inputContexts = [
        for (var index = 0; index < conversion.inputs.length; index++)
          firstContext + index,
      ],
      outputContext = conversion.output == null
          ? null
          : firstContext + conversion.inputs.length;
}

final class ModulePlan {
  /// Import the selected entry surface, not the origin of a re-exported member.
  final Uri source;
  final List<FunctionPlan> functions;
  final List<ClassPlan> classes;
  final List<FunctionValueCallPlan> functionValues;
  final List<CallPlan> calls;
  final List<ValueConversion> conversions;
  final List<ClassBinding> allClasses;
  final List<ValueClassSchema> valueSchemas;
  final List<int> referenceClassOrder;
  late final Map<int, int> resourcePolicies = analysis.resourcePolicies(
    classes.map((binding) => binding.shape).toList(),
  );
  late final bool hasResourceCollections =
      resourcePolicies.isNotEmpty &&
      conversionGraph(conversions).any(
        (value) => containsJsCollectionReference(value, classes: allClasses),
      );
  late final bool hasResourceCallbacks =
      resourcePolicies.isNotEmpty &&
      conversionGraph(conversions).whereType<CallbackConversion>().any(
        (callback) =>
            conversionDependencies([...callback.inputs, ?callback.output])
                .any((conversion) => conversion is ReferenceConversion) ||
            hasDefaultResources(const [], [
              ...callback.inputs,
              ?callback.output,
            ], allClasses),
      );
  bool get hasScopedResourceAccess =>
      hasResourceCollections || hasResourceCallbacks;

  bool needsResourceOperation(CallPlan call) =>
      resourcePolicies.isNotEmpty &&
      (hasScopedResourceAccess ||
          (call is MemberCallPlan && !call.isStatic) ||
          conversionGraph(call.inputs).any((c) => c is ReferenceConversion) ||
          hasDefaultResources(call.parameters, call.inputs, allClasses));
  ModulePlan._(
    this.source,
    Iterable<FunctionPlan> functions,
    Iterable<ClassPlan> classes,
    Iterable<FunctionValueCallPlan> functionValues,
    Iterable<CallPlan> calls,
    Iterable<ValueConversion> conversions,
    Iterable<ClassBinding> allClasses,
    Iterable<ValueClassSchema> valueSchemas,
    this.referenceClassOrder,
  ) : functions = List.unmodifiable(functions),
      classes = List.unmodifiable(classes),
      functionValues = List.unmodifiable(functionValues),
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
  final functionValues = <FunctionValueCallPlan>[];
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
  final contracts = <String>{};
  final functionConversions = conversionDependencies(conversions)
      .whereType<CallbackConversion>()
      .toList();
  for (final conversion in functionConversions) {
    if (conversion.direction == ValueDirection.output &&
        contracts.add(conversion.signatureKey)) {
      final call = FunctionValueCallPlan._(
        conversion,
        functionValues.length,
        conversions.length,
      );
      functionValues.add(call);
      add(call);
    }
  }
  for (final conversion in functionConversions) {
    if (!conversions.contains(conversion)) conversions.add(conversion);
  }
  final plan = ModulePlan._(
    module.bindings.importUri,
    functions,
    classes,
    functionValues,
    calls,
    conversions,
    module.bindings.classes,
    module.valueSchemas,
    referenceClassOrder(module.classes),
  );
  for (final function in functions) {
    function._hasScopedResourceAccess =
        plan.hasScopedResourceAccess ||
        hasDefaultResources(
          function.parameters,
          function.inputs,
          plan.allClasses,
        );
  }
  return plan;
}
