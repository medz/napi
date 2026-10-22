import '../../api/annotation.dart' show ClassPolicy;
import '../ir/model.dart';
import '../ir/defaults.dart';
import 'result.dart';

final dictionaryDeclaration = DeclarationId(
  Uri.parse('package:napi/src/api/dictionary.dart'),
  'Dictionary',
  kind: DeclarationKind.extensionType,
);

final abortSignalDeclaration = DeclarationId(
  Uri.parse('package:napi/src/api/cancellation.dart'),
  'AbortSignal',
  kind: DeclarationKind.classType,
);

bool isAbortSignalType(BindingType type) =>
    type is DeclaredType &&
    type.declaration == abortSignalDeclaration &&
    type.typeArguments.isEmpty &&
    type.nullability != TypeNullability.legacy;

final sharedBytesDeclaration = DeclarationId(
  Uri.parse('package:napi/src/api/shared_bytes.dart'),
  'SharedBytes',
  kind: DeclarationKind.classType,
);

final jsArrayDeclaration = DeclarationId(
  Uri.parse('package:napi/src/api/js_collections.dart'),
  'JsArray',
  kind: DeclarationKind.classType,
);
final jsMapDeclaration = DeclarationId(
  Uri.parse('package:napi/src/api/js_collections.dart'),
  'JsMap',
  kind: DeclarationKind.classType,
);
bool isJsCollectionType(BindingType type) =>
    type is DeclaredType &&
    (type.declaration == jsArrayDeclaration ||
        type.declaration == jsMapDeclaration) &&
    type.nullability != TypeNullability.legacy;

bool isSharedBytesType(BindingType type) =>
    type is DeclaredType &&
    type.declaration == sharedBytesDeclaration &&
    type.typeArguments.isEmpty &&
    type.nullability != TypeNullability.legacy;

final uint8ListDeclaration = DeclarationId(
  Uri.parse('dart:typed_data'),
  'Uint8List',
  kind: DeclarationKind.classType,
);

final byteBufferDeclaration = DeclarationId(
  Uri.parse('dart:typed_data'),
  'ByteBuffer',
  kind: DeclarationKind.classType,
);

/// Ordinary binary bindings copy the visible bytes in either direction.
/// Typedef spelling and similarly named user classes do not change identity.
bool isBinaryType(BindingType type) =>
    type is DeclaredType &&
    (type.declaration == uint8ListDeclaration ||
        type.declaration == byteBufferDeclaration) &&
    type.typeArguments.isEmpty &&
    type.nullability != TypeNullability.legacy;

final class BindingDiagnostic implements Exception {
  final String code;
  final String message;
  final SourceLocation? source;
  const BindingDiagnostic(this.code, this.message, [this.source]);
  @override
  String toString() => '$code${source == null ? '' : ' at $source'}: $message';
}

/// A descriptive declaration model checked independently of backend support.
///
/// The model constructors normalize defaults and freeze collection metadata;
/// this wrapper preserves source order and does not discard unsupported shapes.
final class ValidatedDeclarations {
  final BindingModule bindings;
  const ValidatedDeclarations._(this.bindings);
}

/// A declaration model accepted by the current executable backend.
/// Only this wrapper can be passed to lowering.
final class ValidatedModule {
  final BindingModule bindings;
  final List<ReferenceClassShape> classes;
  final List<ValueClassSchema> valueSchemas;
  ValidatedModule._(
    this.bindings,
    Iterable<ReferenceClassShape> classes,
    Iterable<ValueClassSchema> values,
  ) : classes = List.unmodifiable(classes),
      valueSchemas = List.unmodifiable(values);
}

enum ReferenceMemberKind { constructor, method, getter, setter }

/// Static methods have their own binders; constructors use the class binders.
List<TypeParameterBinding> referenceCallTypeParameters(
  ClassBinding owner,
  MemberBinding member,
) => [
  if (!member.isStatic || member.kind == MemberKind.constructor)
    ...owner.typeParameters,
  ...member.typeParameters,
];

/// Common selected class semantics; target-specific ABI names live in lowering.
final class ReferenceMemberShape {
  final MemberBinding binding;
  final ReferenceMemberKind kind;
  final List<ParameterBinding> parameters;
  final BindingType? result;
  final bool isCleanup;
  bool get returnsFuture => isCleanup || isFutureType(result);
  bool get returnsStream => isStreamType(result);
  bool get isStatic =>
      kind == ReferenceMemberKind.constructor || binding.isStatic;
  String get exportName => binding.exportName ?? binding.declaration.name;
  ReferenceMemberShape._(
    this.binding,
    this.kind,
    Iterable<ParameterBinding> parameters,
    this.result, {
    this.isCleanup = false,
  }) : parameters = List.unmodifiable(parameters);
}

typedef ReferenceMemberRef = ({int classId, int memberIndex});

/// One own JS prototype descriptor; references retain the declaring binding.
final class ReferencePropertyShape {
  final String name;
  final ReferenceMemberRef? method;
  final ReferenceMemberRef? getter;
  final ReferenceMemberRef? setter;
  const ReferencePropertyShape({
    required this.name,
    this.method,
    this.getter,
    this.setter,
  });
}

final class ReferenceClassShape {
  final ClassBinding binding;
  final ReferenceMemberShape? constructor;

  /// Own selected members only; references use these stable indices.
  final List<ReferenceMemberShape> members;
  final int classId;
  final Set<int> memberships;
  final int? superclassId;

  /// For each selected generic ancestor, its parameter slots in this scope.
  /// Only full bijections are supported; runtime carriers keep their own owner.
  final Map<int, List<int>> ancestorArguments;
  final List<ReferencePropertyShape> prototypeProperties;
  ReferenceMemberShape? get cleanup =>
      members.where((member) => member.isCleanup).singleOrNull;
  ReferenceClassShape._(
    this.binding,
    this.constructor,
    Iterable<ReferenceMemberShape> members, {
    required this.classId,
    Iterable<int> memberships = const [],
    this.superclassId,
    Map<int, List<int>> ancestorArguments = const {},
    Iterable<ReferencePropertyShape> prototypeProperties = const [],
  }) : members = List.unmodifiable(members),
       memberships = Set.unmodifiable(memberships),
       ancestorArguments = Map.unmodifiable({
         for (final entry in ancestorArguments.entries)
           entry.key: List<int>.unmodifiable(entry.value),
       }),
       prototypeProperties = List.unmodifiable(prototypeProperties);
}

/// Project a contract only across a proven selected ancestor relationship.
/// The declaring binding and defaults stay intact for runtime dispatch.
ReferenceMemberShape? referenceMemberInScope(
  ReferenceMemberShape member,
  ReferenceClassShape owner,
  ReferenceClassShape scope, {
  // TypeScript may rename a method binder that would capture a projected
  // class binder. Runtime dispatch continues to use the declaring binding.
  Map<DeclarationId, DeclarationId> methodParameters = const {},
}) {
  if (owner.classId == scope.classId && methodParameters.isEmpty) return member;
  final parameters = <DeclarationId, DeclarationId>{...methodParameters};
  if (scope.ancestorArguments[owner.classId] case final slots?) {
    for (final (index, slot) in slots.indexed) {
      parameters[owner.binding.typeParameters[index].declaration] =
          scope.binding.typeParameters[slot].declaration;
    }
  } else if (owner.ancestorArguments[scope.classId] case final slots?) {
    for (final (index, slot) in slots.indexed) {
      parameters[owner.binding.typeParameters[slot].declaration] =
          scope.binding.typeParameters[index].declaration;
    }
  } else if (!scope.memberships.contains(owner.classId) &&
      !owner.memberships.contains(scope.classId)) {
    return null;
  }
  if (parameters.isEmpty) return member;
  return ReferenceMemberShape._(
    member.binding,
    member.kind,
    member.parameters.map((p) => projectOpaqueParameter(p, parameters)),
    member.result == null
        ? null
        : projectOpaqueType(member.result!, parameters),
    isCleanup: member.isCleanup,
  );
}

ParameterBinding projectOpaqueParameter(
  ParameterBinding parameter,
  Map<DeclarationId, DeclarationId> parameters,
) => ParameterBinding(
  parameter.name,
  projectOpaqueType(parameter.type, parameters),
  presence: parameter.presence,
  kind: parameter.kind,
  defaultSource: parameter.defaultSource,
  defaultValue: parameter.defaultValue,
  defaultIdentity: parameter.defaultIdentity,
  defaultObjects: parameter.defaultObjects,
  defaultTypeIsAssignable: parameter.defaultTypeIsAssignable,
  hasDefault: parameter.hasDefault,
  source: parameter.source,
  documentation: parameter.documentation,
  isInitializingFormal: parameter.isInitializingFormal,
  isSuperFormal: parameter.isSuperFormal,
  isCovariant: parameter.isCovariant,
);

BindingType projectOpaqueType(
  BindingType type,
  Map<DeclarationId, DeclarationId> parameters,
) => switch (type) {
  TypeParameterType() => TypeParameterType(
    parameters[type.declaration] ?? type.declaration,
    nullability: type.nullability,
    alias: type.alias,
  ),
  DeclaredType() => DeclaredType(
    type.declaration,
    type.semantics,
    typeArguments: type.typeArguments.map(
      (t) => projectOpaqueType(t, parameters),
    ),
    nullability: type.nullability,
    alias: type.alias,
  ),
  RecordTypeBinding() => RecordTypeBinding(
    positional: type.positional.map((t) => projectOpaqueType(t, parameters)),
    named: {
      for (final e in type.named.entries)
        e.key: projectOpaqueType(e.value, parameters),
    },
    nullability: type.nullability,
    alias: type.alias,
  ),
  FunctionTypeBinding() => FunctionTypeBinding(
    parameters: type.parameters.map(
      (p) => projectOpaqueParameter(p, parameters),
    ),
    result: projectOpaqueType(type.result, parameters),
    typeParameters: type.typeParameters,
    nullability: type.nullability,
    alias: type.alias,
  ),
  _ => type,
};

/// A strict subtype has every ancestor membership plus its own class ID.
/// Stable ID tie breaking keeps unrelated classes in declaration order.
List<int> referenceClassOrder(List<ReferenceClassShape> classes) =>
    List.unmodifiable(
      classes.map((shape) => shape.classId).toList()..sort((a, b) {
        final depth = classes[b].memberships.length.compareTo(
          classes[a].memberships.length,
        );
        return depth == 0 ? a.compareTo(b) : depth;
      }),
    );

/// The selected parents named by a merged TypeScript instance interface.
Iterable<int> referenceParents(
  ReferenceClassShape shape,
  List<ReferenceClassShape> classes,
) {
  final parents = shape.memberships.where((id) => id != shape.classId).toList();
  return parents.where(
    (id) => !parents.any(
      (other) => other != id && classes[other].memberships.contains(id),
    ),
  );
}

/// A finite declaration node; recursive field types refer back by identity.
final class ValueFieldSchema {
  final MemberBinding binding;
  final String name;
  final BindingType type;
  const ValueFieldSchema(this.binding, this.name, this.type);
}

final class ValueInputFieldSchema {
  final ParameterBinding parameter;
  final String name;
  final ValueFieldSchema? field;
  const ValueInputFieldSchema(this.parameter, this.name, {this.field});
}

final class ValueClassSchema {
  final ClassBinding binding;
  final MemberBinding? constructor;
  final List<ValueFieldSchema> outputFields;
  final List<ValueInputFieldSchema> inputFields;
  ValueClassSchema(
    this.binding,
    this.constructor,
    Iterable<ValueFieldSchema> output,
    Iterable<ValueInputFieldSchema> input,
  ) : outputFields = List.unmodifiable(output),
      inputFields = List.unmodifiable(input);
}

DeclaredType valueClassType(ClassBinding binding) =>
    binding.instantiatedType ??
    DeclaredType(
      binding.declaration,
      ValueSemantics.reference,
      typeArguments: binding.typeParameters.map(
        (parameter) => TypeParameterType(parameter.declaration),
      ),
    );

/// Open value instances carry only opaque parameters, just like references.
Map<DeclarationId, DeclarationId> valueClassParameterProjection(
  ClassBinding binding,
  DeclaredType type,
) {
  final arguments = referenceTypeArguments(binding, type)!;
  return {
    for (final (index, parameter) in binding.typeParameters.indexed)
      parameter.declaration:
          (arguments[index] as TypeParameterType).declaration,
  };
}

List<ValueClassSchema> validateValueClasses(BindingModule module) {
  final result = <ValueClassSchema>[];
  for (final binding in module.classes.where(
    (c) => c.classPolicy == ClassPolicy.value,
  )) {
    Never reject(String message, [SourceLocation? source]) =>
        throw BindingDiagnostic(
          'NAPI_VALUE',
          message,
          source ?? binding.source,
        );
    _referenceName(binding.exportName, binding.source, topLevel: true);
    _referencePath(binding.callPath, binding.source);
    if (binding.exportSurface != module.source) {
      reject('The value class must be exposed by the entry library.');
    }
    final opaque = validateOpaqueParameters(
      binding.typeParameters,
      binding.source,
    );
    final fields = <ValueFieldSchema>[];
    for (final member in binding.members) {
      if (member.selection == MemberSelection.excluded) continue;
      if (member.kind == MemberKind.constructor) continue;
      final readable =
          !member.isStatic &&
          (member.kind == MemberKind.field || member.kind == MemberKind.getter);
      if (!readable) {
        if (member.selection == MemberSelection.explicit) {
          reject(
            'Only own instance fields and getters form value data; exclude this configured member.',
            member.source,
          );
        }
        continue;
      }
      if (member.isAsync ||
          member.isGenerator ||
          member.isExternal ||
          member.typeParameters.isNotEmpty) {
        reject(
          'A value member must be synchronous, concrete Dart data.',
          member.source,
        );
      }
      final type = member.kind == MemberKind.field
          ? member.type
          : member.result;
      if (type == null || type is VoidType || member.parameters.isNotEmpty) {
        reject(
          'A readable value member requires a value type and no parameters.',
          member.source,
        );
      }
      _referenceName(
        member.exportName ?? member.declaration.name,
        member.source,
      );
      _referencePath(member.callPath ?? member.declaration.name, member.source);
      validateValueType(
        type,
        member.source,
        referenceClasses: module.classes,
        opaqueParameters: opaque,
      );
      fields.add(
        ValueFieldSchema(
          member,
          member.exportName ?? member.declaration.name,
          type,
        ),
      );
    }
    MemberBinding? constructor;
    final inputs = <ValueInputFieldSchema>[];
    final id = binding.valueConstructor;
    if (id != null) {
      final matches = binding.members
          .where((m) => m.declaration == id)
          .toList();
      if (matches.length != 1 ||
          id.owner != binding.declaration ||
          id.library != binding.declaration.library ||
          id.kind != DeclarationKind.constructor) {
        reject('A value input requires one resolved own constructor.');
      }
      constructor = matches.single;
      if (constructor.kind != MemberKind.constructor ||
          constructor.declaration.name.startsWith('_') ||
          constructor.selection == MemberSelection.excluded) {
        reject(
          'A value constructor must be public and selected.',
          constructor.source,
        );
      }
      if (binding.isAbstract && !constructor.isFactory) {
        reject(
          'An abstract value class requires a factory constructor.',
          constructor.source,
        );
      }
      if (constructor.isExternal || constructor.typeParameters.isNotEmpty) {
        reject(
          'A value constructor must be concrete and non-generic.',
          constructor.source,
        );
      }
      final parameters = constructor.parameters.map((p) => p.name).toSet();
      if (parameters.length != constructor.parameters.length) {
        reject(
          'Value constructor parameters must have distinct Dart names.',
          constructor.source,
        );
      }
      for (final entry in binding.valueFields.entries) {
        if (!parameters.contains(entry.key)) {
          reject(
            'Unknown valueFields parameter ${entry.key}.',
            constructor.source,
          );
        }
        if (!fields.any((f) => f.binding.declaration == entry.value)) {
          reject(
            'valueFields must select a public own readable field or getter.',
          );
        }
      }
      final names = <String>{};
      for (final parameter in constructor.parameters) {
        final override = binding.valueFields[parameter.name];
        final matches = fields
            .where(
              (f) => override == null
                  ? f.binding.declaration.name == parameter.name
                  : f.binding.declaration == override,
            )
            .toList();
        if (matches.length > 1) {
          reject(
            'No unique selected field/getter for constructor parameter ${parameter.name}.',
            parameter.source,
          );
        }
        final field = matches.firstOrNull;
        final name = field?.name ?? parameter.name;
        if (!names.add(name)) {
          reject('Duplicate value input property $name.', parameter.source);
        }
        inputs.add(ValueInputFieldSchema(parameter, name, field: field));
      }
    } else if (binding.valueFields.isNotEmpty) {
      reject('valueFields requires an unambiguous public constructor.');
    }
    result.add(ValueClassSchema(binding, constructor, fields, inputs));
  }
  return List.unmodifiable(result);
}

final _identifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
const javascriptReservedWords = {
  'await',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'debugger',
  'default',
  'delete',
  'do',
  'else',
  'enum',
  'export',
  'extends',
  'false',
  'finally',
  'for',
  'function',
  'if',
  'implements',
  'import',
  'in',
  'instanceof',
  'interface',
  'let',
  'new',
  'null',
  'package',
  'private',
  'protected',
  'public',
  'return',
  'static',
  'super',
  'switch',
  'this',
  'throw',
  'true',
  'try',
  'typeof',
  'var',
  'void',
  'while',
  'with',
  'yield',
};

final _dartIdentifier = RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$');

/// Validate declaration integrity without choosing a conversion engine or ABI.
///
/// Classes, named and optional parameters, nullable types, aliases, generics,
/// records and function types are all retained. Backend limitations belong in
/// [validate], not in discovery or this descriptive validation step.
ValidatedDeclarations validateDeclarations(BindingModule module) {
  if (module.source.scheme != 'file' ||
      !{'file', 'package'}.contains(module.importUri.scheme) ||
      (module.functions.isEmpty && module.classes.isEmpty)) {
    throw const BindingDiagnostic(
      'NAPI_INPUT',
      'Provide a file library and at least one exported declaration.',
    );
  }
  final exports = <String>{};
  final declarations = <DeclarationId>{};
  void checkExport(
    DeclarationId declaration,
    String exportName,
    SourceLocation source,
  ) {
    _checkSource(source);
    if (!_dartIdentifier.hasMatch(declaration.name) ||
        declaration.name.startsWith('_') ||
        declaration.owner != null) {
      throw BindingDiagnostic(
        'NAPI_NAME',
        'Expected a public top-level Dart declaration identifier.',
        source,
      );
    }
    if (!_dartIdentifier.hasMatch(exportName)) {
      throw BindingDiagnostic(
        'NAPI_NAME',
        'Expected an export identifier.',
        source,
      );
    }
    if (!exports.add(exportName) || !declarations.add(declaration)) {
      throw BindingDiagnostic(
        'NAPI_DUPLICATE',
        'Duplicate export $exportName.',
        source,
      );
    }
  }

  for (final function in module.functions) {
    checkExport(function.declaration, function.exportName, function.source);
    _checkParameters(function.parameters, function.source);
    _checkTypeParameters(function.typeParameters, function.source);
    _checkType(function.result, function.source);
  }
  for (final binding in module.classes) {
    final selection = binding.selectionDeclaration;
    final instance = binding.instantiatedType;
    if ((selection == null) != (instance == null) ||
        (selection != null && selection.kind != DeclarationKind.typedefType) ||
        (instance != null &&
            (instance.declaration != binding.declaration ||
                instance.semantics != ValueSemantics.reference ||
                instance.nullability != TypeNullability.nonNullable))) {
      throw BindingDiagnostic(
        'NAPI_DECLARATION',
        'A class alias must identify its selected typedef and original non-null class instance.',
        binding.source,
      );
    }
    checkExport(
      binding.selectionDeclaration ?? binding.declaration,
      binding.exportName,
      binding.source,
    );
    if (binding.instantiatedType case final type?) {
      _checkType(type, binding.source);
    }
    for (final type in binding.concreteSupertypes) {
      if (instance == null ||
          type.declaration != binding.declaration ||
          type.nullability != TypeNullability.nonNullable) {
        throw BindingDiagnostic(
          'NAPI_DECLARATION',
          'Concrete supertypes must describe instances of the same original class.',
          binding.source,
        );
      }
      _checkType(type, binding.source);
    }
    _checkTypeParameters(binding.typeParameters, binding.source);
    if (binding.supertype case final type?) {
      _checkType(type, binding.source);
    }
    for (final type in [...binding.interfaces, ...binding.mixins]) {
      _checkType(type, binding.source);
    }
    for (final type in [...binding.allSupertypes, ...binding.superclassChain]) {
      _checkType(type, binding.source);
      if (type.nullability != TypeNullability.nonNullable) {
        throw BindingDiagnostic(
          'NAPI_DECLARATION',
          'Ancestor types must be non-null.',
          binding.source,
        );
      }
    }
    final members = <DeclarationId>{};
    for (final member in binding.members) {
      _checkSource(member.source);
      if (member.declaration.owner != binding.declaration ||
          member.declaration.library != binding.declaration.library) {
        throw BindingDiagnostic(
          'NAPI_DECLARATION',
          'Member identity must identify its declaring class and library.',
          member.source,
        );
      }
      if (!members.add(member.declaration)) {
        throw BindingDiagnostic(
          'NAPI_DUPLICATE',
          'Duplicate member ${member.declaration.name}.',
          member.source,
        );
      }
      _checkParameters(member.parameters, member.source);
      _checkTypeParameters(member.typeParameters, member.source);
      if (member.result case final type?) _checkType(type, member.source);
      if (member.type case final type?) _checkType(type, member.source);
    }
    _checkClassPolicy(binding);
    _checkMemberExports(binding);
  }
  return ValidatedDeclarations._(module);
}

void _checkClassPolicy(ClassBinding binding) {
  if (binding.classPolicy != ClassPolicy.value &&
      (binding.valueConstructor != null || binding.valueFields.isNotEmpty)) {
    throw BindingDiagnostic(
      'NAPI_SELECTION',
      'Value construction options require the value class policy.',
      binding.source,
    );
  }
  final cleanup = binding.cleanup;
  if (binding.classPolicy != ClassPolicy.resource) {
    if (cleanup != null) {
      throw BindingDiagnostic(
        'NAPI_SELECTION',
        'cleanup requires the resource class policy.',
        binding.source,
      );
    }
    return;
  }
  if (cleanup == null) {
    throw BindingDiagnostic(
      'NAPI_SELECTION',
      'A resource policy requires a cleanup method.',
      binding.source,
    );
  }
  final members = binding.members
      .where((member) => member.declaration == cleanup)
      .toList();
  if (members.length != 1 ||
      cleanup.owner != binding.declaration ||
      cleanup.library != binding.declaration.library) {
    throw BindingDiagnostic(
      'NAPI_SELECTION',
      'Cleanup must refer to one declared member of its owning class.',
      binding.source,
    );
  }
  final member = members.single;
  if (member.declaration.name.startsWith('_')) {
    throw BindingDiagnostic(
      'NAPI_VISIBILITY',
      'A cleanup method must be public.',
      member.source,
    );
  }
  if (member.kind != MemberKind.method ||
      cleanup.kind != DeclarationKind.method ||
      member.isStatic) {
    throw BindingDiagnostic(
      'NAPI_SELECTION',
      'Cleanup must select a declared instance method.',
      member.source,
    );
  }
}

void _checkMemberExports(ClassBinding binding) {
  final properties = <(bool, String), MemberBinding>{};
  final accessors = <(bool, String), MemberBinding>{};
  final constructors = <String, MemberBinding>{};
  for (final member in binding.members) {
    // Value exports are data properties. Other explicit selections are checked
    // by validateValueClasses, while implicit methods/setters are not exports.
    if (binding.classPolicy == ClassPolicy.value &&
        (member.isStatic ||
            (member.kind != MemberKind.field &&
                member.kind != MemberKind.getter))) {
      continue;
    }
    final selected = member.selection != MemberSelection.excluded;
    final exportName = member.exportName ?? member.declaration.name;
    if ((member.hasExplicitExportName || selected) &&
        // Operator spelling is descriptive metadata, not a chosen JS name.
        !(member.isOperator && !member.hasExplicitExportName) &&
        // An unnamed constructor has no assigned runtime export name.
        !(member.kind == MemberKind.constructor && member.exportName == null) &&
        (!_dartIdentifier.hasMatch(exportName) || exportName.startsWith('_'))) {
      throw BindingDiagnostic(
        'NAPI_NAME',
        'Expected a public member export identifier.',
        member.source,
      );
    }
    if (!selected) continue;
    if (member.kind == MemberKind.constructor) {
      final name = member.exportName;
      if (name != null && constructors.containsKey(name)) {
        throw BindingDiagnostic(
          'NAPI_DUPLICATE',
          'Duplicate constructor export $name.',
          member.source,
        );
      }
      if (name != null) constructors[name] = member;
      continue;
    }
    final isAccessor =
        member.kind == MemberKind.getter || member.kind == MemberKind.setter;
    if (isAccessor) {
      final propertyKey = (member.isStatic, member.declaration.name);
      final previous = accessors[propertyKey];
      if (previous != null &&
          (previous.exportName ?? previous.declaration.name) != exportName) {
        throw BindingDiagnostic(
          'NAPI_SELECTION',
          'The selected getter and setter of ${member.declaration.name} '
              'must use the same export name.',
          member.source,
        );
      }
      accessors[propertyKey] = member;
    }
    final exportKey = (member.isStatic, exportName);
    final previous = properties[exportKey];
    if (previous != null &&
        !(isAccessor &&
            previous.declaration.name == member.declaration.name &&
            ((previous.kind == MemberKind.getter &&
                    member.kind == MemberKind.setter) ||
                (previous.kind == MemberKind.setter &&
                    member.kind == MemberKind.getter)))) {
      throw BindingDiagnostic(
        'NAPI_DUPLICATE',
        'Duplicate ${member.isStatic ? 'static' : 'instance'} '
            'member export $exportName.',
        member.source,
      );
    }
    properties[exportKey] = member;
  }
}

void _checkSource(SourceLocation source) {
  if (source.offset < 0 ||
      source.length < 0 ||
      (source.line != null && source.line! < 1) ||
      (source.column != null && source.column! < 1)) {
    throw BindingDiagnostic(
      'NAPI_SOURCE',
      'Source offsets must be nonnegative and line/column must be one-based.',
      source,
    );
  }
}

void _checkParameters(
  List<ParameterBinding> parameters,
  SourceLocation source, {
  bool allowUnnamed = false,
}) {
  final names = <String>{};
  for (final parameter in parameters) {
    final parameterSource = parameter.source ?? source;
    _checkSource(parameterSource);
    if (!(allowUnnamed && parameter.name.isEmpty) &&
        (!_dartIdentifier.hasMatch(parameter.name) ||
            (parameter.name != '_' && !names.add(parameter.name)))) {
      throw BindingDiagnostic(
        'NAPI_PARAMETER',
        'Invalid or duplicate parameter name.',
        parameterSource,
      );
    }
    _checkType(parameter.type, parameterSource);
  }
}

void _checkTypeParameters(
  List<TypeParameterBinding> parameters,
  SourceLocation source,
) {
  final names = <String>{};
  for (final parameter in parameters) {
    final parameterSource = parameter.source ?? source;
    _checkSource(parameterSource);
    if (!_dartIdentifier.hasMatch(parameter.declaration.name) ||
        (parameter.declaration.name != '_' &&
            !names.add(parameter.declaration.name))) {
      throw BindingDiagnostic(
        'NAPI_PARAMETER',
        'Invalid or duplicate type parameter name.',
        parameterSource,
      );
    }
    if (parameter.bound case final type?) _checkType(type, parameterSource);
    if (parameter.defaultType case final type?) {
      _checkType(type, parameterSource);
    }
  }
}

void _checkType(BindingType type, SourceLocation source) {
  if (type.alias case final alias?) {
    for (final argument in alias.typeArguments) {
      _checkType(argument, source);
    }
  }
  switch (type) {
    case DeclaredType():
      for (final argument in type.typeArguments) {
        _checkType(argument, source);
      }
    case FunctionTypeBinding():
      _checkTypeParameters(type.typeParameters, source);
      _checkParameters(type.parameters, source, allowUnnamed: true);
      _checkType(type.result, source);
    case RecordTypeBinding():
      for (final field in type.positional) {
        _checkType(field, source);
      }
      for (final entry in type.named.entries) {
        if (!_dartIdentifier.hasMatch(entry.key)) {
          throw BindingDiagnostic(
            'NAPI_TYPE',
            'Invalid named record field ${entry.key}.',
            source,
          );
        }
        _checkType(entry.value, source);
      }
    case SafeIntType() ||
        TypeParameterType() ||
        DynamicType() ||
        VoidType() ||
        NeverType():
      break;
  }
}

/// Check the scalar and structural backend, after declaration checks.
///
/// Unsupported metadata is rejected explicitly; it is never erased to make a
/// declaration fit the backend or silently omitted from the lowered module.
ValidatedModule validate(BindingModule module) {
  final declarations = validateDeclarations(module);
  final values = validateValueClasses(module);
  final classes = validateReferenceClasses(module);
  for (final function in module.functions) {
    void reject(String code, String message) =>
        throw BindingDiagnostic(code, message, function.source);
    if (function.exportSurface != module.source) {
      reject(
        'NAPI_LIBRARY',
        'The call path must be exposed by the selected entry library.',
      );
    }
    if (function.callPath
        .split('.')
        .any(
          (segment) =>
              !_identifier.hasMatch(segment) ||
              segment.startsWith('_') ||
              javascriptReservedWords.contains(segment),
        )) {
      reject('NAPI_NAME', 'Expected a public Dart function call path.');
    }
    if (!_identifier.hasMatch(function.exportName) ||
        javascriptReservedWords.contains(function.exportName) ||
        // These are valid Dart identifiers and declaration parameter names,
        // but cannot be local bindings in an unaliased strict-mode ESM import.
        const {'eval', 'arguments'}.contains(function.exportName) ||
        function.exportName == 'then' ||
        function.exportName.startsWith('wasm_')) {
      reject('NAPI_NAME', 'Export name is not a supported public identifier.');
    }
    final opaque = validateOpaqueParameters(
      function.typeParameters,
      function.source,
    );
    if (function.isExternal) {
      reject(
        'NAPI_EXTERNAL',
        'External functions require an external-capable backend.',
      );
    }
    validateCallParameters(
      function.parameters,
      function.source,
      referenceClasses: module.classes,
      opaqueParameters: opaque,
    );
    validateCallResult(
      function.result,
      function.source,
      referenceClasses: module.classes,
      isAsync: function.isAsync,
      isGenerator: function.isGenerator,
      opaqueParameters: opaque,
    );
  }
  return ValidatedModule._(declarations.bindings, classes, values);
}

void _validateAliasSelections(BindingModule module) {
  final aliases = module.classes.where(
    (binding) => binding.instantiatedType != null,
  );
  for (final binding in aliases) {
    final type = binding.instantiatedType!;
    final opaque = opaqueParameterIds(binding.typeParameters);
    if (referenceTypeArguments(binding, type) == null ||
        type.typeArguments.any(
          (argument) => !_isConcreteOrOpaqueType(argument, opaque),
        )) {
      throw BindingDiagnostic(
        'NAPI_GENERIC',
        'Class alias arguments must contain only closed types and their own opaque parameters, with every alias parameter represented.',
        binding.source,
      );
    }
    for (final other in module.classes) {
      if (identical(binding, other) ||
          other.declaration != binding.declaration) {
        continue;
      }
      if (other.instantiatedType == null) {
        throw BindingDiagnostic(
          'NAPI_GENERIC',
          'Select either the original class or its class aliases, not both.',
          binding.source,
        );
      }
      if (referenceClassMatches(other, type)) {
        throw BindingDiagnostic(
          'NAPI_GENERIC',
          'Select one export for each canonical class instance.',
          binding.source,
        );
      }
    }
  }
}

/// Whether an explicit specialization contains no open or dynamic arguments.
bool isClosedConcreteType(BindingType type) =>
    _isConcreteOrOpaqueType(type, const {});

bool _isConcreteOrOpaqueType(BindingType type, Set<DeclarationId> opaque) {
  bool supported(BindingType child) => _isConcreteOrOpaqueType(child, opaque);
  return type.nullability != TypeNullability.legacy &&
      switch (type) {
        DynamicType() => false,
        TypeParameterType() => isOpaqueType(type, opaque),
        DeclaredType(:final typeArguments) => typeArguments.every(supported),
        RecordTypeBinding(:final positional, :final named) =>
          positional.every(supported) && named.values.every(supported),
        FunctionTypeBinding(
          :final typeParameters,
          :final parameters,
          :final result,
        ) =>
          typeParameters.isEmpty &&
              parameters.every((p) => supported(p.type)) &&
              supported(result),
        _ => true,
      };
}

/// Shared reference-class call contracts, without target ABI choices.
List<ReferenceClassShape> validateReferenceClasses(BindingModule module) {
  _validateAliasSelections(module);
  final result = <ReferenceClassShape>[];
  for (final binding in module.classes.where(
    (c) => c.classPolicy != ClassPolicy.value,
  )) {
    Never reject(String code, String message, [SourceLocation? source]) =>
        throw BindingDiagnostic(code, message, source ?? binding.source);
    _referenceName(binding.exportName, binding.source, topLevel: true);
    _referencePath(binding.callPath, binding.source);
    if (binding.exportSurface != module.source) {
      reject('NAPI_LIBRARY', 'The class must be exposed by the entry library.');
    }
    final opaque = validateOpaqueParameters(
      binding.typeParameters,
      binding.source,
    );
    if (opaque.any((p) => p.name == binding.exportName)) {
      reject(
        'NAPI_NAME',
        'Opaque type parameters must not shadow their exported class name ${binding.exportName}.',
      );
    }
    if (binding.cleanup case final cleanup?) {
      final member = binding.members.singleWhere(
        (member) => member.declaration == cleanup,
      );
      if (member.selection == MemberSelection.excluded) {
        reject(
          'NAPI_RESOURCE',
          'A resource cleanup method must be selected for explicit disposal.',
          member.source,
        );
      }
    }
    ReferenceMemberShape? constructor;
    final members = <ReferenceMemberShape>[];
    ReferenceMemberShape call(
      MemberBinding member,
      ReferenceMemberKind kind,
      List<ParameterBinding> parameters,
      BindingType? type,
    ) {
      final isCleanup = member.declaration == binding.cleanup;
      final callOpaque = opaqueParameterIds(
        referenceCallTypeParameters(binding, member),
      );
      validateCallParameters(
        parameters,
        member.source,
        referenceClasses: module.classes,
        opaqueParameters: callOpaque,
      );
      validateCallResult(
        type,
        member.source,
        referenceClasses: module.classes,
        isAsync: member.isAsync,
        isGenerator: member.isGenerator,
        opaqueParameters: callOpaque,
      );
      if (isCleanup && (isStreamType(type) || resultPayload(type) != null)) {
        reject(
          'NAPI_RESOURCE',
          'A cleanup method must return void or Future<void>.',
          member.source,
        );
      }
      return ReferenceMemberShape._(
        member,
        kind,
        parameters,
        type is VoidType ? null : type,
        isCleanup: isCleanup,
      );
    }

    for (final member in binding.members) {
      if (member.selection == MemberSelection.excluded) continue;
      if (member.typeParameters.isNotEmpty) {
        if (member.kind != MemberKind.method ||
            member.declaration == binding.cleanup) {
          reject(
            'NAPI_GENERIC',
            'Only ordinary instance and static methods support opaque method parameters.',
            member.source,
          );
        }
        validateOpaqueParameters(member.typeParameters, member.source);
      }
      if (member.isExternal) {
        reject(
          'NAPI_EXTERNAL',
          'Dart external members are not supported.',
          member.source,
        );
      }
      if (member.kind == MemberKind.constructor) {
        if (binding.isAbstract && !member.isFactory) {
          reject(
            'NAPI_CONSTRUCTOR',
            'An abstract class requires a factory constructor.',
            member.source,
          );
        }
        final unnamed = member.declaration.name == 'new';
        if (unnamed && member.hasExplicitExportName) {
          reject(
            'NAPI_CONSTRUCTOR',
            'An unnamed constructor cannot be renamed.',
            member.source,
          );
        }
        final selected = call(
          member,
          ReferenceMemberKind.constructor,
          member.parameters,
          null,
        );
        if (unnamed) {
          constructor = selected;
        } else {
          final name = selected.exportName;
          _referenceName(name, member.source);
          if (const {'length', 'prototype'}.contains(name)) {
            reject(
              'NAPI_NAME',
              'Constructor $name conflicts with the JavaScript class shape.',
              member.source,
            );
          }
          _referencePath(
            member.callPath ?? member.declaration.name,
            member.source,
          );
          members.add(selected);
        }
        continue;
      }
      final name = member.exportName ?? member.declaration.name;
      _referenceName(name, member.source);
      if ((!member.isStatic && name == 'constructor') ||
          (member.isStatic && const {'length', 'prototype'}.contains(name))) {
        reject(
          'NAPI_NAME',
          'Member $name conflicts with the JavaScript class shape.',
          member.source,
        );
      }
      if (member.isOperator) {
        reject('NAPI_MEMBER', 'Operators are not implemented.', member.source);
      }
      _referencePath(member.callPath ?? member.declaration.name, member.source);
      if (member.kind == MemberKind.field) {
        final type = member.type;
        if (type == null) {
          reject(
            'NAPI_TYPE',
            'A field requires its resolved type.',
            member.source,
          );
        }
        members.add(call(member, ReferenceMemberKind.getter, const [], type));
        if (!member.isFinal && !member.isConst) {
          members.add(
            call(member, ReferenceMemberKind.setter, [
              ParameterBinding(
                'value',
                type,
                source: member.source,
                presence: isOpaqueType(type, opaque)
                    ? ParameterPresence.opaqueRequired
                    : null,
              ),
            ], null),
          );
        }
      } else {
        if (member.result == null) {
          reject(
            'NAPI_TYPE',
            'A member requires its resolved result type.',
            member.source,
          );
        }
        final kind = switch (member.kind) {
          MemberKind.method => ReferenceMemberKind.method,
          MemberKind.getter => ReferenceMemberKind.getter,
          MemberKind.setter => ReferenceMemberKind.setter,
          _ => throw StateError('Handled above'),
        };
        if ((kind == ReferenceMemberKind.getter &&
                member.parameters.isNotEmpty) ||
            (kind == ReferenceMemberKind.setter &&
                (member.parameters.length != 1 ||
                    member.parameters.single.kind !=
                        ParameterKind.requiredPositional))) {
          reject(
            'NAPI_MEMBER',
            'Invalid getter or setter parameter shape.',
            member.source,
          );
        }
        members.add(
          call(
            member,
            kind,
            member.parameters,
            kind == ReferenceMemberKind.setter ? null : member.result,
          ),
        );
      }
    }
    final staticNames = <String, ReferenceMemberShape>{};
    for (final member in members.where((member) => member.isStatic)) {
      final previous = staticNames[member.exportName];
      if (previous != null &&
          (member.kind == ReferenceMemberKind.constructor ||
              previous.kind == ReferenceMemberKind.constructor)) {
        reject(
          'NAPI_DUPLICATE',
          'Duplicate static export ${member.exportName}.',
          member.binding.source,
        );
      }
      staticNames[member.exportName] = member;
    }
    result.add(
      ReferenceClassShape._(
        binding,
        constructor,
        members,
        classId: result.length,
      ),
    );
  }
  final shapes = _referenceHierarchy(result);
  for (final shape in shapes) {
    if (shape.ancestorArguments.isEmpty) continue;
    for (final parent in referenceParents(shape, shapes)) {
      final name = shapes[parent].binding.exportName;
      if (shape.binding.typeParameters.any((p) => p.declaration.name == name)) {
        throw BindingDiagnostic(
          'NAPI_NAME',
          'Opaque type parameters must not shadow the inherited exported class name $name.',
          shape.binding.source,
        );
      }
    }
  }
  final policies = resourcePolicies(shapes);
  for (final shape in shapes) {
    final inheritedPolicies = shape.memberships
        .where(policies.containsKey)
        .map((id) => policies[id])
        .toSet();
    if (inheritedPolicies.length > 1) {
      throw BindingDiagnostic(
        'NAPI_RESOURCE',
        '${shape.binding.exportName} inherits incompatible cleanup policies.',
        shape.binding.source,
      );
    }
  }
  return shapes;
}

List<ReferenceClassShape> _referenceHierarchy(
  List<ReferenceClassShape> classes,
) {
  final bindings = classes.map((shape) => shape.binding).toList();
  int? selected(DeclaredType type) {
    final index = bindings.indexWhere(
      (binding) => referenceClassMatches(binding, type),
    );
    if (index >= 0) return index;
    // An open ancestor with malformed arity is still selected: diagnose its
    // mapping below instead of silently dropping a handwritten IR edge.
    final open = bindings.indexWhere(
      (binding) =>
          binding.instantiatedType == null &&
          binding.typeParameters.isNotEmpty &&
          binding.declaration == type.declaration,
    );
    return open < 0 ? null : open;
  }

  final memberships = <int, Set<int>>{};
  final argumentSlots = <int, Map<int, List<int>>>{};
  final visiting = <int>{};
  Set<int> ancestors(int id) {
    if (memberships[id] case final known?) return known;
    final binding = classes[id].binding;
    if (!visiting.add(id)) {
      throw BindingDiagnostic(
        'NAPI_INHERITANCE',
        'A selected class cannot inherit from itself.',
        binding.source,
      );
    }
    final result = <int>{id};
    final mappings = <int, List<int>>{};
    void mapping(int ancestor, List<int> slots) {
      final previous = mappings[ancestor];
      if (previous != null &&
          (previous.length != slots.length ||
              previous.indexed.any((e) => e.$2 != slots[e.$1]))) {
        throw BindingDiagnostic(
          'NAPI_GENERIC',
          'Selected ancestors must have one consistent opaque parameter mapping.',
          binding.source,
        );
      }
      mappings[ancestor] = slots;
    }

    final ancestorsTypes = <DeclaredType>[
      ...binding.allSupertypes,
      ...binding.superclassChain,
      // These edges also support hand-written IR without resolved ancestors.
      if (binding.supertype case final DeclaredType type) type,
      for (final type in [...binding.interfaces, ...binding.mixins])
        if (type is DeclaredType) type,
    ];
    for (final type in ancestorsTypes) {
      if (selected(type) case final parent?) {
        final parentBinding = classes[parent].binding;
        final generic =
            binding.typeParameters.isNotEmpty ||
            parentBinding.typeParameters.isNotEmpty;
        List<int>? slots;
        if (generic) {
          final parameters = binding.typeParameters
              .map((p) => p.declaration)
              .toList();
          slots = [
            for (final argument
                in referenceTypeArguments(parentBinding, type) ??
                    const <BindingType>[])
              argument is TypeParameterType &&
                      argument.nullability == TypeNullability.nonNullable
                  ? parameters.indexOf(argument.declaration)
                  : -1,
          ];
          if (parameters.length != parentBinding.typeParameters.length ||
              slots.length != parameters.length ||
              slots.contains(-1) ||
              slots.toSet().length != parameters.length) {
            throw BindingDiagnostic(
              'NAPI_GENERIC',
              'Selected open ancestors require a full bijection of non-null opaque parameters.',
              binding.source,
            );
          }
          mapping(parent, slots);
        }
        result.addAll(ancestors(parent));
        if (slots != null) {
          for (final entry in argumentSlots[parent]!.entries) {
            mapping(entry.key, [for (final slot in entry.value) slots[slot]]);
          }
        }
      }
    }
    visiting.remove(id);
    argumentSlots[id] = mappings;
    return memberships[id] = result;
  }

  int? superclass(ClassBinding binding) {
    for (final type in binding.superclassChain) {
      if (selected(type) case final parent?) return parent;
    }
    if (binding.supertype case final DeclaredType type) return selected(type);
    return null;
  }

  // An ordinary selected override keeps the ancestor's cleanup role in every
  // backend, while its own signature/defaults still participate in policy checks.
  Iterable<ReferenceMemberShape> effectiveMembers(ReferenceClassShape shape) {
    if (shape.binding.classPolicy != ClassPolicy.reference) {
      return shape.members;
    }
    final cleanupNames = {
      for (final ancestor in ancestors(shape.classId))
        if (classes[ancestor].cleanup case final cleanup?)
          cleanup.binding.declaration.name,
    };
    if (cleanupNames.length > 1) {
      throw BindingDiagnostic(
        'NAPI_RESOURCE',
        '${shape.binding.exportName} inherits incompatible cleanup policies.',
        shape.binding.source,
      );
    }
    return shape.members.map((member) {
      if (member.isStatic ||
          member.kind != ReferenceMemberKind.method ||
          !cleanupNames.contains(member.binding.declaration.name)) {
        return member;
      }
      if (member.binding.typeParameters.isNotEmpty) {
        throw BindingDiagnostic(
          'NAPI_GENERIC',
          'Cleanup methods cannot declare opaque method parameters.',
          member.binding.source,
        );
      }
      final validResult =
          member.result == null ||
          (isFutureType(member.result) &&
              member.result!.nullability == TypeNullability.nonNullable &&
              resultPayload(member.result) == null);
      if (!validResult) {
        throw BindingDiagnostic(
          'NAPI_RESOURCE',
          'An inherited cleanup override must return void or Future<void>.',
          member.binding.source,
        );
      }
      return ReferenceMemberShape._(
        member.binding,
        member.kind,
        member.parameters,
        member.result,
        isCleanup: true,
      );
    });
  }

  final shapes = [
    for (final shape in classes)
      ReferenceClassShape._(
        shape.binding,
        shape.constructor,
        effectiveMembers(shape),
        classId: shape.classId,
        memberships: ancestors(shape.classId),
        ancestorArguments: argumentSlots[shape.classId]!,
        superclassId: superclass(shape.binding),
      ),
  ];
  final effective = <int, Map<String, ReferencePropertyShape>>{};
  final order = referenceClassOrder(shapes);
  ReferenceMemberShape member(ReferenceMemberRef ref) =>
      shapes[ref.classId].members[ref.memberIndex];
  for (final id in order.reversed) {
    final shape = shapes[id];
    final inherited = effective[shape.superclassId] ?? const {};
    final candidates = <String, List<ReferenceMemberRef>>{};
    final dartNames = <String, String>{};
    Never reject(String message, [SourceLocation? source]) =>
        throw BindingDiagnostic(
          'NAPI_INHERITANCE',
          '${shape.binding.exportName}: $message',
          source ?? shape.binding.source,
        );
    for (final ancestor in order.reversed.where(shape.memberships.contains)) {
      for (final (index, selected) in shapes[ancestor].members.indexed) {
        if (selected.isStatic) continue;
        final name = selected.binding.declaration.name;
        final exported = selected.exportName;
        final previous = dartNames[name];
        if (previous != null && previous != exported) {
          reject(
            'Inherited member $name must retain export name $previous; '
            'renaming it to $exported would hide a selected ancestor contract.',
            selected.binding.source,
          );
        }
        dartNames[name] = exported;
        candidates.putIfAbsent(exported, () => []).add((
          classId: ancestor,
          memberIndex: index,
        ));
      }
    }
    for (final own in shape.binding.members) {
      if (own.isStatic || own.selection != MemberSelection.excluded) continue;
      for (final refs in candidates.values) {
        for (final ref in refs) {
          if (ref.classId == id) continue;
          final selected = member(ref);
          if (selected.binding.declaration.name == own.declaration.name &&
              (own.kind == MemberKind.field ||
                  own.kind.name == selected.kind.name)) {
            reject(
              'Excluded member ${own.declaration.name} is required by a '
              'selected ancestor; excluding it cannot hide that contract.',
              own.source,
            );
          }
        }
      }
    }
    for (final inheritedMember in shape.binding.inheritedInstanceMembers) {
      final actual = inheritedMember.member;
      for (final refs in candidates.values) {
        for (final ref in refs) {
          final contract = member(ref);
          if (contract.binding.declaration != inheritedMember.contract ||
              !referenceClassMatches(
                classes[ref.classId].binding,
                inheritedMember.contractType,
              ) ||
              contract.kind.name != actual.kind.name) {
            continue;
          }
          if (actual.selection == MemberSelection.excluded) {
            reject(
              'Inherited implementation ${actual.declaration.name} is excluded '
              'but is required by a selected ancestor.',
              actual.source,
            );
          }
          if (actual.hasExplicitExportName &&
              actual.exportName != contract.exportName) {
            reject(
              'Inherited implementation ${actual.declaration.name} renames '
              'selected ancestor export ${contract.exportName}.',
              actual.source,
            );
          }
          if (actual.typeParameters.isNotEmpty) {
            if (contract.isCleanup) {
              throw BindingDiagnostic(
                'NAPI_GENERIC',
                'Cleanup methods cannot declare opaque method parameters.',
                actual.source,
              );
            }
            validateOpaqueParameters(actual.typeParameters, actual.source);
          }
          final actualVoid = actual.result is VoidType;
          final contractVoid = contract.result == null;
          final validCleanupResult =
              actualVoid ||
              (isFutureType(actual.result) &&
                  actual.result!.nullability == TypeNullability.nonNullable &&
                  (actual.result! as DeclaredType).typeArguments.length == 1 &&
                  resultPayload(actual.result) == null);
          if (!inheritedMember.isCompatible ||
              (actual.isGenerator &&
                  !(actual.isAsync && isStreamType(actual.result))) ||
              (actual.isAsync &&
                  !(actual.isGenerator
                      ? isStreamType(actual.result)
                      : isFutureType(actual.result))) ||
              (contract.isCleanup
                  ? !validCleanupResult
                  : (isFutureType(actual.result) !=
                            isFutureType(contract.result) ||
                        isStreamType(actual.result) !=
                            isStreamType(contract.result))) ||
              (contract.kind != ReferenceMemberKind.method &&
                  actualVoid != contractVoid)) {
            reject(
              'Inherited implementation ${actual.declaration.name} has an '
              'incompatible parameter or result type for a selected ancestor.',
              actual.source,
            );
          }
        }
      }
    }
    final properties = <String, ReferencePropertyShape>{};
    for (final entry in candidates.entries) {
      final refs = entry.value;
      final originalNames = refs
          .map((ref) => member(ref).binding.declaration.name)
          .toSet();
      if (originalNames.length != 1) {
        reject(
          'Export ${entry.key} maps to different inherited Dart members: '
          '${originalNames.join(', ')}.',
        );
      }
      final kinds = refs.map((ref) => member(ref).kind).toSet();
      if (kinds.contains(ReferenceMemberKind.method) && kinds.length != 1) {
        reject('Export ${entry.key} cannot be both a method and an accessor.');
      }
      ReferenceMemberRef? select(ReferenceMemberKind kind) {
        final matching = refs.where((ref) => member(ref).kind == kind).toList();
        if (matching.isEmpty) return null;
        // Prefer an own/most-specific declaration. For equivalent interface
        // contracts, retain the existing extends descriptor where possible.
        final closest =
            matching
                .where(
                  (ref) => !matching.any(
                    (other) =>
                        ref.classId != other.classId &&
                        shapes[other.classId].memberships.contains(ref.classId),
                  ),
                )
                .toList()
              ..sort((a, b) => a.classId.compareTo(b.classId));
        final inheritedProperty = inherited[entry.key];
        final inheritedRef = switch (kind) {
          ReferenceMemberKind.method => inheritedProperty?.method,
          ReferenceMemberKind.getter => inheritedProperty?.getter,
          ReferenceMemberKind.setter => inheritedProperty?.setter,
          ReferenceMemberKind.constructor => null,
        };
        final compatible = closest
            .where(
              (candidate) => matching.every(
                (ref) => referenceMemberAccepts(
                  referenceMemberInScope(
                    member(candidate),
                    shapes[candidate.classId],
                    shape,
                  )!,
                  referenceMemberInScope(
                    member(ref),
                    shapes[ref.classId],
                    shape,
                  )!,
                  shapes,
                  opaqueInheritance: shape.ancestorArguments.isNotEmpty,
                ),
              ),
            )
            .toList();
        if (compatible.isEmpty) {
          reject(
            'Member ${entry.key} has an incompatible inherited parameter, '
            'presence or result conversion; select an own compatible override.',
            member(closest.first).binding.source,
          );
        }
        return compatible.contains(inheritedRef)
            ? inheritedRef!
            : compatible.first;
      }

      properties[entry.key] = ReferencePropertyShape(
        name: entry.key,
        method: select(ReferenceMemberKind.method),
        getter: select(ReferenceMemberKind.getter),
        setter: select(ReferenceMemberKind.setter),
      );
    }
    effective[id] = properties;
    shapes[id] = ReferenceClassShape._(
      shape.binding,
      shape.constructor,
      shape.members,
      classId: id,
      memberships: shape.memberships,
      ancestorArguments: shape.ancestorArguments,
      superclassId: shape.superclassId,
      prototypeProperties: properties.values.where((property) {
        final previous = inherited[property.name];
        return previous == null ||
            property.method != previous.method ||
            property.getter != previous.getter ||
            property.setter != previous.setter;
      }),
    );
  }
  return List.unmodifiable(shapes);
}

/// Whether one selected callback covers another selected conversion contract.
/// Declaration-owned defaults are checked separately when composing views.
bool referenceMemberAccepts(
  ReferenceMemberShape implementation,
  ReferenceMemberShape contract,
  List<ReferenceClassShape> classes, {
  bool opaqueInheritance = false,
}) {
  final actualTypes = implementation.binding.typeParameters;
  final expectedTypes = contract.binding.typeParameters;
  final parameters = <DeclarationId, DeclarationId>{};
  if (actualTypes.isNotEmpty || expectedTypes.isNotEmpty) {
    if (actualTypes.length != expectedTypes.length) return false;
    for (final (index, actual) in actualTypes.indexed) {
      final expected = expectedTypes[index];
      // Opaque method bounds have already been validated as Object/Object?.
      // An omitted bound is Object?; a stricter bound is a different contract.
      bool nullableBound(TypeParameterBinding p) =>
          p.bound == null || p.bound!.nullability == TypeNullability.nullable;
      if (nullableBound(actual) != nullableBound(expected)) return false;
      parameters[expected.declaration] = actual.declaration;
    }
  }
  bool subtype(BindingType child, BindingType parent) =>
      _referenceSubtype(child, parent, classes);
  bool optional(ParameterBinding p) =>
      p.presence == ParameterPresence.optional ||
      ((opaqueInheritance || actualTypes.isNotEmpty) &&
          p.presence == ParameterPresence.opaqueOptional);
  final output = implementation.result;
  final requiredOutput = parameters.isEmpty || contract.result == null
      ? contract.result
      : projectOpaqueType(contract.result!, parameters);
  final requiredParameters = parameters.isEmpty
      ? contract.parameters
      : contract.parameters.map((p) => projectOpaqueParameter(p, parameters));
  if (implementation.isCleanup != contract.isCleanup ||
      implementation.returnsFuture != contract.returnsFuture ||
      implementation.returnsStream != contract.returnsStream) {
    return false;
  }
  // A void method contract discards its result. The derived binding retains
  // its own conversion, while explicitly borrowing the base still returns void.
  final discardsResult =
      contract.kind == ReferenceMemberKind.method && requiredOutput == null;
  if (!contract.isCleanup &&
      !discardsResult &&
      ((output == null) != (requiredOutput == null) ||
          (output != null && !subtype(output, requiredOutput!)))) {
    return false;
  }
  bool positional(ParameterBinding p) =>
      p.kind == ParameterKind.requiredPositional ||
      p.kind == ParameterKind.optionalPositional;
  final actual = implementation.parameters.where(positional).toList();
  final expected = requiredParameters.where(positional).toList();
  if (actual.length < expected.length) return false;
  for (final (index, parameter) in actual.indexed) {
    if (index >= expected.length) {
      if (!optional(parameter)) return false;
      continue;
    }
    final previous = expected[index];
    if ((optional(previous) && !optional(parameter)) ||
        !subtype(previous.type, parameter.type)) {
      return false;
    }
  }
  final actualNamed = {
    for (final p in implementation.parameters.where((p) => !positional(p)))
      p.name: p,
  };
  final expectedNamed = {
    for (final p in requiredParameters.where((p) => !positional(p))) p.name: p,
  };
  // Named options occupy the slot after every positional parameter. A new
  // positional slot would move that object and break the inherited JS call.
  if (expectedNamed.isNotEmpty && actual.length != expected.length) {
    return false;
  }
  for (final entry in expectedNamed.entries) {
    final parameter = actualNamed[entry.key];
    final previous = entry.value;
    if (parameter == null ||
        (optional(previous) && !optional(parameter)) ||
        !subtype(previous.type, parameter.type)) {
      return false;
    }
  }
  return actualNamed.values.every(
    (p) => expectedNamed.containsKey(p.name) || optional(p),
  );
}

bool _referenceSubtype(
  BindingType child,
  BindingType parent,
  List<ReferenceClassShape> classes,
) {
  if (child.nullability == TypeNullability.nullable &&
      parent.nullability != TypeNullability.nullable) {
    return false;
  }
  if (child is SafeIntType && parent is SafeIntType) return true;
  if (child is VoidType && parent is VoidType) return true;
  if (child is TypeParameterType && parent is TypeParameterType) {
    return child.declaration == parent.declaration;
  }
  if (child is FunctionTypeBinding && parent is FunctionTypeBinding) {
    if (child.typeParameters.isNotEmpty || parent.typeParameters.isNotEmpty) {
      return false;
    }
    bool positional(ParameterBinding p) =>
        p.kind == ParameterKind.requiredPositional ||
        p.kind == ParameterKind.optionalPositional;
    final actual = child.parameters.where(positional).toList();
    final expected = parent.parameters.where(positional).toList();
    if (actual.length < expected.length ||
        actual.where((p) => p.kind == ParameterKind.requiredPositional).length >
            expected
                .where((p) => p.kind == ParameterKind.requiredPositional)
                .length) {
      return false;
    }
    for (final (index, parameter) in expected.indexed) {
      if (!_referenceSubtype(parameter.type, actual[index].type, classes)) {
        return false;
      }
    }
    final actualNamed = {
      for (final p in child.parameters.where((p) => !positional(p))) p.name: p,
    };
    final expectedNamed = {
      for (final p in parent.parameters.where((p) => !positional(p))) p.name: p,
    };
    // Extra positional slots must not shift the JavaScript options object.
    if (expectedNamed.isNotEmpty && actual.length != expected.length) {
      return false;
    }
    for (final entry in expectedNamed.entries) {
      final parameter = actualNamed[entry.key];
      if (parameter == null ||
          parameter.kind == ParameterKind.requiredNamed &&
              entry.value.kind != ParameterKind.requiredNamed ||
          !_referenceSubtype(entry.value.type, parameter.type, classes)) {
        return false;
      }
    }
    if (actualNamed.values.any(
      (p) =>
          p.kind == ParameterKind.requiredNamed &&
          !expectedNamed.containsKey(p.name),
    )) {
      return false;
    }
    return parent.result is VoidType ||
        _referenceSubtype(child.result, parent.result, classes);
  }
  if (child is DeclaredType && parent is DeclaredType) {
    final childId = classes.indexWhere(
      (c) => referenceClassMatches(c.binding, child),
    );
    final parentId = classes.indexWhere(
      (c) => referenceClassMatches(c.binding, parent),
    );
    if (childId >= 0 && parentId >= 0) {
      final selected = classes[childId];
      if (!selected.memberships.contains(parentId)) return false;
      if (selected.binding.typeParameters.isEmpty) return true;
      final childArguments = referenceTypeArguments(selected.binding, child)!;
      final parentArguments = referenceTypeArguments(
        classes[parentId].binding,
        parent,
      )!;
      final slots = childId == parentId
          ? [for (var i = 0; i < childArguments.length; i++) i]
          : selected.ancestorArguments[parentId];
      return slots != null &&
          slots.length == parentArguments.length &&
          slots.indexed.every(
            (e) =>
                _sameCanonicalType(childArguments[e.$2], parentArguments[e.$1]),
          );
    }
    if (child.declaration != parent.declaration ||
        classes.any(
          (c) =>
              c.binding.declaration == child.declaration &&
              c.binding.instantiatedType != null,
        )) {
      return child.declaration == parent.declaration &&
          child.typeArguments.length == parent.typeArguments.length &&
          child.typeArguments.indexed.every(
            (e) => _sameCanonicalType(e.$2, parent.typeArguments[e.$1]),
          );
    }
    return child.typeArguments.length == parent.typeArguments.length &&
        child.typeArguments.indexed.every(
          (entry) => _referenceSubtype(
            entry.$2,
            parent.typeArguments[entry.$1],
            classes,
          ),
        );
  }
  if (child is RecordTypeBinding && parent is RecordTypeBinding) {
    return child.positional.length == parent.positional.length &&
        child.named.length == parent.named.length &&
        child.positional.indexed.every(
          (entry) =>
              _referenceSubtype(entry.$2, parent.positional[entry.$1], classes),
        ) &&
        child.named.entries.every(
          (entry) =>
              parent.named.containsKey(entry.key) &&
              _referenceSubtype(entry.value, parent.named[entry.key]!, classes),
        );
  }
  return false;
}

void _referenceName(
  String name,
  SourceLocation source, {
  bool topLevel = false,
}) {
  if (!_identifier.hasMatch(name) ||
      (!topLevel && name.startsWith('_')) ||
      javascriptReservedWords.contains(name) ||
      const {'eval', 'arguments'}.contains(name) ||
      (topLevel && name == 'then')) {
    throw BindingDiagnostic(
      'NAPI_NAME',
      'Unsupported public class identifier $name.',
      source,
    );
  }
}

void _referencePath(String path, SourceLocation source) {
  if (path
      .split('.')
      .any((part) => !_identifier.hasMatch(part) || part.startsWith('_'))) {
    throw BindingDiagnostic(
      'NAPI_NAME',
      'Unsupported Dart class call path $path.',
      source,
    );
  }
}

/// Validate the completion contract before lowering its ordinary payload.
void validateCallResult(
  BindingType? type,
  SourceLocation source, {
  List<ClassBinding> referenceClasses = const [],
  bool isAsync = false,
  bool isGenerator = false,
  Set<DeclarationId> opaqueParameters = const {},
}) {
  Never reject(String message) =>
      throw BindingDiagnostic('NAPI_TYPE', message, source);
  final future = isFutureType(type);
  final stream = isStreamType(type);
  if (isGenerator && !(isAsync && stream)) {
    reject('Generator exports must use async* and return Stream<T>.');
  }
  if (isAsync && !isGenerator && !future) {
    reject('An async export must declare a non-nullable Future<T> result.');
  }
  if (future &&
      (type!.nullability != TypeNullability.nonNullable ||
          (type as DeclaredType).typeArguments.length != 1)) {
    reject('A Future result must be non-nullable with one payload type.');
  }
  if (stream &&
      (type!.nullability != TypeNullability.nonNullable ||
          (type as DeclaredType).typeArguments.length != 1)) {
    reject('A Stream result must be non-nullable with one payload type.');
  }
  final payload = resultPayload(type);
  if (payload == null) return;
  validateValueType(
    payload,
    source,
    referenceClasses: referenceClasses,
    opaqueParameters: opaqueParameters,
  );
}

/// Supported declaration parameters share the default non-null payload carrier.
Set<DeclarationId> opaqueParameterIds(List<TypeParameterBinding> parameters) =>
    {
      for (final parameter in parameters)
        if (parameter.opaque) parameter.declaration,
    };

Set<DeclarationId> validateOpaqueParameters(
  List<TypeParameterBinding> parameters,
  SourceLocation source,
) {
  final selected = opaqueParameterIds(parameters);
  if (selected.length != parameters.length) {
    throw BindingDiagnostic(
      'NAPI_GENERIC',
      'Generic parameters must have the default JavaScript payload mapping.',
      source,
    );
  }
  for (final parameter in parameters) {
    final name = parameter.declaration.name;
    if (!_identifier.hasMatch(name) ||
        name == '_' ||
        javascriptReservedWords.contains(name) ||
        const {
          'any',
          'unknown',
          'never',
          'number',
          'string',
          'boolean',
          'bigint',
          'symbol',
          'object',
          'undefined',
          'keyof',
          'infer',
          'readonly',
          'unique',
          'is',
          'asserts',
        }.contains(name)) {
      throw BindingDiagnostic(
        'NAPI_PARAMETER',
        'Unsupported opaque type-parameter name $name.',
        parameter.source ?? source,
      );
    }
    final bound = parameter.bound;
    if (bound != null &&
        !(bound is DeclaredType &&
            bound.declaration ==
                DeclarationId(
                  Uri.parse('dart:core'),
                  'Object',
                  kind: DeclarationKind.classType,
                ) &&
            bound.typeArguments.isEmpty &&
            bound.nullability != TypeNullability.legacy)) {
      throw BindingDiagnostic(
        'NAPI_TYPE',
        'Opaque parameter $name must have an Object or Object? bound.',
        parameter.source ?? source,
      );
    }
  }
  return selected;
}

bool isOpaqueType(BindingType type, Set<DeclarationId> parameters) =>
    type is TypeParameterType &&
    type.nullability != TypeNullability.legacy &&
    parameters.contains(type.declaration);

/// Match the canonical Dart instance, ignoring typedef spelling and the use
/// site's outer nullability. Selected aliases are invariant boundary views.
bool referenceClassMatches(ClassBinding binding, DeclaredType type) =>
    referenceTypeArguments(binding, type) != null;

/// Logical arguments of a selected alias, excluding its fixed Dart arguments.
/// A repeated parameter must refer to the same use-site parameter each time.
List<BindingType>? referenceTypeArguments(
  ClassBinding binding,
  DeclaredType type,
) {
  if (binding.declaration != type.declaration) return null;
  final concrete = binding.instantiatedType;
  if (concrete == null) {
    return binding.typeParameters.length == type.typeArguments.length
        ? type.typeArguments
        : null;
  }
  if (concrete.typeArguments.length != type.typeArguments.length) return null;
  final parameters = opaqueParameterIds(binding.typeParameters);
  final projected = <DeclarationId, BindingType>{};
  bool matchParameter(TypeParameterType pattern, TypeParameterType argument) {
    if (parameters.contains(pattern.declaration)) {
      // The nullable marker belongs to the alias shape, not its logical slot.
      final projectedArgument = TypeParameterType(argument.declaration);
      if (projected[pattern.declaration] case final previous?) {
        if (!_sameCanonicalType(previous, projectedArgument)) return false;
      }
      projected[pattern.declaration] = projectedArgument;
      return true;
    }
    return pattern.declaration == argument.declaration;
  }

  for (final (index, pattern) in concrete.typeArguments.indexed) {
    if (!_matchCanonicalType(
      pattern,
      type.typeArguments[index],
      matchParameter,
    )) {
      return null;
    }
  }
  final arguments = <BindingType>[];
  for (final parameter in binding.typeParameters) {
    final argument = projected[parameter.declaration];
    if (argument == null) return null;
    arguments.add(argument);
  }
  return arguments;
}

bool _sameCanonicalType(BindingType left, BindingType right) =>
    _matchCanonicalType(left, right, (a, b) => a.declaration == b.declaration);

bool _matchCanonicalType(
  BindingType left,
  BindingType right,
  bool Function(TypeParameterType, TypeParameterType) matchParameter,
) {
  if (left.nullability != right.nullability) return false;
  bool match(BindingType a, BindingType b) =>
      _matchCanonicalType(a, b, matchParameter);
  return switch ((left, right)) {
    (SafeIntType(), SafeIntType()) ||
    (DynamicType(), DynamicType()) ||
    (VoidType(), VoidType()) ||
    (NeverType(), NeverType()) => true,
    (TypeParameterType a, TypeParameterType b) => matchParameter(a, b),
    (DeclaredType a, DeclaredType b) =>
      a.declaration == b.declaration &&
          a.typeArguments.length == b.typeArguments.length &&
          a.typeArguments.indexed.every(
            (entry) => match(entry.$2, b.typeArguments[entry.$1]),
          ),
    (RecordTypeBinding a, RecordTypeBinding b) =>
      a.positional.length == b.positional.length &&
          a.named.length == b.named.length &&
          a.positional.indexed.every(
            (entry) => match(entry.$2, b.positional[entry.$1]),
          ) &&
          a.named.entries.every(
            (entry) =>
                b.named.containsKey(entry.key) &&
                match(entry.value, b.named[entry.key]!),
          ),
    (FunctionTypeBinding a, FunctionTypeBinding b) =>
      a.typeParameters.isEmpty &&
          b.typeParameters.isEmpty &&
          match(a.result, b.result) &&
          a.parameters.length == b.parameters.length &&
          a.parameters.indexed.every((entry) {
            final other = b.parameters[entry.$1];
            return entry.$2.kind == other.kind &&
                (!const {
                      ParameterKind.requiredNamed,
                      ParameterKind.optionalNamed,
                    }.contains(entry.$2.kind) ||
                    entry.$2.name == other.name) &&
                match(entry.$2.type, other.type);
          }),
    _ => false,
  };
}

/// Only direct references to selected public classes have a runtime mapping.
bool isReferenceType(
  BindingType type,
  List<ClassBinding> classes, {
  Set<DeclarationId> opaqueParameters = const {},
}) =>
    type is DeclaredType &&
    type.nullability != TypeNullability.legacy &&
    type.semantics == ValueSemantics.reference &&
    classes.any(
      (binding) =>
          binding.classPolicy != ClassPolicy.value &&
          referenceClassMatches(binding, type) &&
          (binding.typeParameters.isEmpty ||
              binding.typeParameters.every((p) => p.opaque) &&
                  referenceTypeArguments(binding, type)!.every(
                    (t) =>
                        t.nullability == TypeNullability.nonNullable &&
                        isOpaqueType(t, opaqueParameters),
                  )),
    );

/// Scalar/structural values and selected reference leaves share one capability
/// check. Reference leaves must name a selected, non-generic public class.
void validateValueType(
  BindingType type,
  SourceLocation source, {
  List<ClassBinding> referenceClasses = const [],
  ValueDirection direction = ValueDirection.output,
  Set<DeclarationId> opaqueParameters = const {},
  bool allowAbortSignal = false,
}) {
  if (isJsCollectionType(type)) {
    _validateJsCollection(
      type as DeclaredType,
      source,
      referenceClasses,
      opaqueParameters,
    );
    return;
  }
  if (allowAbortSignal &&
      direction == ValueDirection.input &&
      isAbortSignalType(type)) {
    return;
  }
  if (_containsAbortSignal(type)) {
    throw BindingDiagnostic(
      'NAPI_CANCELLATION',
      'AbortSignal requires a direct input; signal outputs, containers and callback payloads are not supported.',
      source,
    );
  }
  if (opaqueParameters.isNotEmpty) {
    validateOpaqueReferenceNames(
      type,
      source,
      referenceClasses,
      opaqueParameters,
    );
  }
  if (isOpaqueType(type, opaqueParameters) ||
      isReferenceType(
        type,
        referenceClasses,
        opaqueParameters: opaqueParameters,
      )) {
    return;
  }
  _checkValueDirection(
    type,
    source,
    referenceClasses,
    direction,
    <(ClassBinding, ValueDirection)>{},
    opaqueParameters,
  );
  if (!_isBackendValue(
    type,
    referenceClasses,
    direction,
    null,
    opaqueParameters,
  )) {
    throw BindingDiagnostic(
      'NAPI_TYPE',
      'No scalar, structural or selected class reference conversion for this type.',
      source,
    );
  }
}

bool _containsAbortSignal(BindingType type) => switch (type) {
  DeclaredType() =>
    type.declaration == abortSignalDeclaration ||
        type.typeArguments.any(_containsAbortSignal),
  RecordTypeBinding() =>
    type.positional.any(_containsAbortSignal) ||
        type.named.values.any(_containsAbortSignal),
  FunctionTypeBinding() =>
    _containsAbortSignal(type.result) ||
        type.parameters.any(
          (parameter) => _containsAbortSignal(parameter.type),
        ),
  _ => false,
};

void _validateJsCollection(
  DeclaredType collection,
  SourceLocation source,
  List<ClassBinding> classes,
  Set<DeclarationId> opaqueParameters,
) {
  validateOpaqueReferenceNames(collection, source, classes, opaqueParameters);
  if (!_supportedJsCollectionElements(collection, classes, opaqueParameters)) {
    throw BindingDiagnostic(
      'NAPI_JS_COLLECTION',
      'JsArray/JsMap support scalars, selected references, binary values, SharedBytes, opaque elements, typed functions, nested JS collection handles, value classes and copied containers. Stream-returning function elements are unsupported. Copied Map keys cannot contain typed functions.',
      source,
    );
  }
}

bool _supportedJsCollectionElements(
  DeclaredType collection,
  List<ClassBinding> classes,
  Set<DeclarationId> opaqueParameters, {
  Set<(ClassBinding, bool)>? visited,
}) =>
    collection.typeArguments.length ==
        (collection.declaration == jsMapDeclaration ? 2 : 1) &&
    collection.typeArguments.every(
      (type) => _supportedJsCollectionElement(
        type,
        classes,
        opaqueParameters,
        visited: visited ?? {},
      ),
    );

bool _supportedJsCollectionElement(
  BindingType type,
  List<ClassBinding> classes,
  Set<DeclarationId> opaqueParameters, {
  bool mapKey = false,
  required Set<(ClassBinding, bool)> visited,
}) {
  if (type.nullability == TypeNullability.legacy) return false;
  if (isOpaqueType(type, opaqueParameters)) return true;
  if (isReferenceType(type, classes, opaqueParameters: opaqueParameters)) {
    return true;
  }
  if (isJsCollectionType(type)) {
    return _supportedJsCollectionElements(
      type as DeclaredType,
      classes,
      opaqueParameters,
      visited: visited,
    );
  }
  if (_isBackendScalar(type) || isBinaryType(type) || isSharedBytesType(type)) {
    return true;
  }
  if (type is FunctionTypeBinding) {
    final result = type.result;
    if (mapKey ||
        type.typeParameters.isNotEmpty ||
        type.parameters.any((parameter) => parameter.hasDefault) ||
        isStreamType(result) ||
        isFutureType(result) &&
            (result.nullability != TypeNullability.nonNullable ||
                (result as DeclaredType).typeArguments.length != 1)) {
      return false;
    }
    bool payload(BindingType value) => _supportedJsCollectionElement(
      value,
      classes,
      opaqueParameters,
      visited: visited,
    );
    final output = resultPayload(result);
    return type.parameters.every((parameter) => payload(parameter.type)) &&
        (output == null || payload(output)) &&
        _isBackendValue(
          type,
          classes,
          ValueDirection.input,
          null,
          opaqueParameters,
        ) &&
        _isBackendValue(
          type,
          classes,
          ValueDirection.output,
          null,
          opaqueParameters,
        );
  }
  bool child(BindingType value, {bool key = false}) =>
      _supportedJsCollectionElement(
        value,
        classes,
        opaqueParameters,
        mapKey: mapKey || key,
        visited: visited,
      );
  if (_valueClassBinding(type, classes) case final binding?) {
    if (!_valueClassArgumentsSupported(
      binding,
      type as DeclaredType,
      opaqueParameters,
    )) {
      return false;
    }
    if (!visited.add((binding, mapKey))) return true;
    _validateValueConstructorInputs(binding, classes);
    return [
      ..._valueChildren(binding, ValueDirection.input, type),
      ..._valueChildren(binding, ValueDirection.output, type),
    ].every(child);
  }
  if (type is RecordTypeBinding) {
    return type.positional.every(child) && type.named.values.every(child);
  }
  if (type is! DeclaredType || type.semantics != ValueSemantics.structural) {
    return false;
  }
  final declaration = type.declaration;
  final arity = declaration == dictionaryDeclaration
      ? 1
      : declaration ==
            DeclarationId(
              Uri.parse('dart:core'),
              'List',
              kind: DeclarationKind.classType,
            )
      ? 1
      : declaration ==
            DeclarationId(
              Uri.parse('dart:core'),
              'Map',
              kind: DeclarationKind.classType,
            )
      ? 2
      : 0;
  return arity != 0 &&
      type.typeArguments.length == arity &&
      type.typeArguments.indexed.every(
        (entry) => child(entry.$2, key: arity == 2 && entry.$1 == 0),
      );
}

void _validateCallback(
  FunctionTypeBinding type,
  SourceLocation source,
  ValueDirection direction,
) {
  Never reject(String message) =>
      throw BindingDiagnostic('NAPI_CALLBACK', message, source);
  if (type.typeParameters.isNotEmpty) {
    reject('Generic callback signatures are not supported.');
  }
  if (type.nullability == TypeNullability.legacy) {
    reject('Legacy callback nullability is not supported.');
  }
  if (type.parameters.any((parameter) => parameter.hasDefault)) {
    reject('Function types cannot declare parameter defaults.');
  }
  final result = type.result;
  if (isStreamType(result) && direction == ValueDirection.input) {
    reject(
      'Stream results are not supported in JavaScript callback signatures.',
    );
  }
  if ((isFutureType(result) || isStreamType(result)) &&
      (result.nullability != TypeNullability.nonNullable ||
          (result as DeclaredType).typeArguments.length != 1)) {
    reject(
      'A function Future or Stream result must be non-nullable with one payload type.',
    );
  }
}

/// Export renames may collide even when the original Dart names are distinct.
/// Reject class-name shadowing in an emitted opaque parameter scope.
void validateOpaqueReferenceNames(
  BindingType type,
  SourceLocation source,
  List<ClassBinding> classes,
  Set<DeclarationId> parameters,
) {
  // Value fields live in module-level private TS aliases. Open values expose
  // only opaque arguments here; their selected class name cannot be captured.
  if (_valueClassBinding(type, classes) != null) return;
  if (type is DeclaredType) {
    for (final binding in classes) {
      if (binding.classPolicy != ClassPolicy.value &&
          referenceClassMatches(binding, type)) {
        if (parameters.any((p) => p.name == binding.exportName)) {
          throw BindingDiagnostic(
            'NAPI_NAME',
            'Opaque type parameters must not shadow the referenced exported class name ${binding.exportName}.',
            source,
          );
        }
        // Closed aliases emit their selected name without type arguments.
        if (binding.instantiatedType != null &&
            binding.typeParameters.isEmpty) {
          return;
        }
      }
    }
  }
  for (final child in switch (type) {
    DeclaredType() => type.typeArguments,
    RecordTypeBinding() => [...type.positional, ...type.named.values],
    _ => <BindingType>[],
  }) {
    validateOpaqueReferenceNames(child, source, classes, parameters);
  }
}

void validateReferenceType(
  BindingType type,
  SourceLocation source,
  List<ClassBinding> classes,
) {
  if (!_isBackendScalar(type) && !isReferenceType(type, classes)) {
    throw BindingDiagnostic(
      'NAPI_TYPE',
      'No scalar or selected class reference conversion for this type.',
      source,
    );
  }
}

void validateScalarType(BindingType type, SourceLocation source) {
  if (!_isBackendScalar(type)) {
    throw BindingDiagnostic(
      'NAPI_TYPE',
      'No scalar conversion for this ${type.semantics.name} type.',
      source,
    );
  }
}

/// Validate ordinary presence/default semantics for either backend.
void validateCallParameters(
  List<ParameterBinding> parameters,
  SourceLocation source, {
  bool scalarOnly = false,
  bool validateTypes = true,
  bool allowResourceDefaults = true,
  List<ClassBinding> referenceClasses = const [],
  Set<DeclarationId> opaqueParameters = const {},
}) {
  var optionalPositional = false;
  var named = false;
  for (final parameter in parameters) {
    void reject(String code, String message) =>
        throw BindingDiagnostic(code, message, parameter.source ?? source);
    if (!_identifier.hasMatch(parameter.name) ||
        javascriptReservedWords.contains(parameter.name)) {
      reject('NAPI_PARAMETER', 'Unsupported backend parameter name.');
    }
    final optional =
        parameter.kind == ParameterKind.optionalPositional ||
        parameter.kind == ParameterKind.optionalNamed;
    final opaque = isOpaqueType(parameter.type, opaqueParameters);
    if (parameter.presence !=
        (opaque
            ? (optional
                  ? ParameterPresence.opaqueOptional
                  : ParameterPresence.opaqueRequired)
            : (optional
                  ? ParameterPresence.optional
                  : ParameterPresence.required))) {
      reject(
        'NAPI_PRESENCE',
        'Parameter presence must match its Dart kind and generic payload mapping.',
      );
    }
    switch (parameter.kind) {
      case ParameterKind.requiredPositional:
        if (optionalPositional || named) {
          reject(
            'NAPI_PARAMETER',
            'Required positional parameters must come first.',
          );
        }
      case ParameterKind.optionalPositional:
        if (named) {
          reject(
            'NAPI_PARAMETER',
            'Dart cannot mix optional positional and named parameters.',
          );
        }
        optionalPositional = true;
      case ParameterKind.requiredNamed || ParameterKind.optionalNamed:
        if (optionalPositional) {
          reject(
            'NAPI_PARAMETER',
            'Dart cannot mix optional positional and named parameters.',
          );
        }
        named = true;
    }
    if (validateTypes && !scalarOnly) {
      validateValueType(
        parameter.type,
        parameter.source ?? source,
        referenceClasses: referenceClasses,
        direction: ValueDirection.input,
        opaqueParameters: opaqueParameters,
        allowAbortSignal: true,
      );
    } else if (validateTypes &&
        !opaque &&
        !_isBackendScalar(parameter.type) &&
        !isReferenceType(
          parameter.type,
          referenceClasses,
          opaqueParameters: opaqueParameters,
        )) {
      reject('NAPI_TYPE', 'No scalar conversion for this type.');
    }
    if (!optional && parameter.hasDefault) {
      reject('NAPI_DEFAULT', 'Required parameters cannot have defaults.');
    }
    if (optional) {
      validateParameterDefault(
        parameter,
        source,
        referenceClasses: referenceClasses,
        opaqueParameters: opaqueParameters,
        allowResourceDefaults: allowResourceDefaults,
      );
    }
  }
}

/// Validate evaluated defaults shared by native and Wasm backends.
void validateParameterDefault(
  ParameterBinding parameter,
  SourceLocation source, {
  List<ClassBinding> referenceClasses = const [],
  Set<DeclarationId> opaqueParameters = const {},
  bool allowResourceDefaults = false,
}) {
  final constant = parameter.defaultValue;
  final value = constant is ScalarDefault ? constant.value : null;
  final type = parameter.type;
  if (constant != null && constant is! ScalarDefault) {
    try {
      constantDefaultSource(
        constant,
        declarationSource: constantDeclarationKey,
      );
    } on ConstantDefaultLimit catch (error) {
      throw BindingDiagnostic(
        'NAPI_DEFAULT',
        error.toString(),
        parameter.source ?? source,
      );
    } on FormatException catch (error) {
      throw BindingDiagnostic(
        'NAPI_DEFAULT',
        error.message,
        parameter.source ?? source,
      );
    }
    final admittedResourceDefault =
        allowResourceDefaults &&
        (isReferenceType(type, referenceClasses) &&
                !isValueClassType(type, referenceClasses) ||
            _resourceContainerDefault(type, referenceClasses));
    final completeGraph = parameter.defaultObjects != null;
    final resourceObjects = defaultResourceObjects(parameter, referenceClasses);
    for (final object in resourceObjects) {
      final expression = object.expression;
      if (expression == null ||
          object.fieldPath.any((field) {
            final name = field.endsWith('!')
                ? field.substring(0, field.length - 1)
                : field;
            return name.startsWith('_') || !_dartIdentifier.hasMatch(name);
          }) ||
          !_defaultResourceHasRuntimeView(object, referenceClasses)) {
        throw BindingDiagnostic(
          'NAPI_DEFAULT',
          'A resource stored in a default requires an accessible constant or public stored field path and a selected concrete resource view.',
          parameter.source ?? source,
        );
      }
      try {
        constantDefaultSource(
          expression,
          declarationSource: constantDeclarationKey,
        );
      } on ConstantDefaultLimit catch (error) {
        throw BindingDiagnostic(
          'NAPI_DEFAULT',
          error.toString(),
          parameter.source ?? source,
        );
      } on FormatException catch (error) {
        throw BindingDiagnostic(
          'NAPI_DEFAULT',
          error.message,
          parameter.source ?? source,
        );
      }
    }
    if ((admittedResourceDefault ||
            _portableDefaultParameter(
              type,
              referenceClasses,
              opaqueParameters: opaqueParameters,
              completeGraph: completeGraph,
            )) &&
        (completeGraph
            ? resourceObjects.isEmpty || allowResourceDefaults
            : admittedResourceDefault ||
                  !_defaultGraphHasResource(constant, referenceClasses)) &&
        _structuralDefaultFits(
          constant,
          type,
          referenceClasses,
          rootTypeIsAssignable:
              parameter.defaultTypeIsAssignable &&
              !_containsOpaque(type, opaqueParameters),
        )) {
      return;
    }
    throw BindingDiagnostic(
      'NAPI_DEFAULT',
      'Non-null defaults require a compatible const graph of scalars, selected '
          'reference/value objects, Lists, Maps, Dictionaries or records. '
          'Object defaults need accessible const constructors or bindings; resource '
          'defaults need a complete stored object graph with accessible resource '
          'leaves. Non-null opaque payload defaults remain unsupported.',
      parameter.source ?? source,
    );
  }
  if (!_isBackendScalar(type) &&
      ((parameter.hasDefault && parameter.defaultValue == null) ||
          value != null)) {
    throw BindingDiagnostic(
      'NAPI_DEFAULT',
      type.semantics == ValueSemantics.reference
          ? 'Non-null reference defaults need a represented public const constructor; a nullable reference parameter may use a null default.'
          : 'Non-null structural defaults must be completely represented const graphs; a nullable structural parameter may use a null default.',
      parameter.source ?? source,
    );
  }
  final valid = parameter.hasDefault && parameter.defaultValue == null
      ? false
      : value == null
      ? type.nullability == TypeNullability.nullable
      : type is SafeIntType
      ? value is int
      : type is! DeclaredType
      ? false
      : switch (type.declaration.name) {
          'bool' => value is bool,
          'String' => value is String,
          'double' => value is double || value is int,
          _ => false,
        };
  if (!valid) {
    throw BindingDiagnostic(
      'NAPI_DEFAULT',
      'Default for ${parameter.name} must resolve to a compatible scalar '
          'constant (or null for a nullable parameter); source expressions '
          'are never copied into generated calls.',
      parameter.source ?? source,
    );
  }
}

bool _isBackendScalar(BindingType type) {
  if (type.nullability == TypeNullability.legacy) return false;
  if (type is SafeIntType) return true;
  return type is DeclaredType &&
      type.semantics == ValueSemantics.scalar &&
      type.typeArguments.isEmpty &&
      type.declaration.library == Uri.parse('dart:core') &&
      type.declaration.kind == DeclarationKind.classType &&
      type.declaration.owner == null &&
      const {
        'bool',
        'String',
        'double',
        'BigInt',
      }.contains(type.declaration.name);
}

ClassBinding? _valueClassBinding(
  BindingType type,
  List<ClassBinding> classes,
) =>
    type is DeclaredType &&
        type.nullability != TypeNullability.legacy &&
        type.semantics == ValueSemantics.reference
    ? classes
          .where(
            (binding) =>
                binding.classPolicy == ClassPolicy.value &&
                referenceClassMatches(binding, type),
          )
          .firstOrNull
    : null;

bool isValueClassType(BindingType type, List<ClassBinding> classes) =>
    _valueClassBinding(type, classes) != null;

bool _valueClassArgumentsSupported(
  ClassBinding binding,
  DeclaredType type,
  Set<DeclarationId> opaqueParameters,
) =>
    binding.typeParameters.isEmpty ||
    binding.typeParameters.every((parameter) => parameter.opaque) &&
        referenceTypeArguments(binding, type)!.every(
          (argument) =>
              argument.nullability == TypeNullability.nonNullable &&
              isOpaqueType(argument, opaqueParameters),
        );

void _validateValueConstructorInputs(
  ClassBinding binding,
  List<ClassBinding> classes,
) {
  final constructor = binding.members
      .where((member) => member.declaration == binding.valueConstructor)
      .firstOrNull;
  if (constructor == null) return;
  // The direction traversal checks recursive field types with one visited set.
  validateCallParameters(
    constructor.parameters,
    constructor.source,
    referenceClasses: classes,
    opaqueParameters: opaqueParameterIds(binding.typeParameters),
    allowResourceDefaults: true,
    validateTypes: false,
  );
}

Iterable<BindingType> _valueChildren(
  ClassBinding binding,
  ValueDirection direction, [
  DeclaredType? instance,
]) {
  final parameters = instance == null
      ? const <DeclarationId, DeclarationId>{}
      : valueClassParameterProjection(binding, instance);
  BindingType project(BindingType type) =>
      parameters.isEmpty ? type : projectOpaqueType(type, parameters);
  if (direction == ValueDirection.input) {
    final constructor = binding.members
        .where((m) => m.declaration == binding.valueConstructor)
        .firstOrNull;
    return constructor?.parameters.map((p) => project(p.type)) ?? const [];
  }
  return binding.members
      .where(
        (m) =>
            m.selection != MemberSelection.excluded &&
            !m.isStatic &&
            (m.kind == MemberKind.field || m.kind == MemberKind.getter),
      )
      .map(
        (m) => project(
          (m.kind == MemberKind.field ? m.type : m.result) ??
              const DynamicType(),
        ),
      );
}

void _checkValueDirection(
  BindingType type,
  SourceLocation source,
  List<ClassBinding> classes,
  ValueDirection direction,
  Set<(ClassBinding, ValueDirection)> visited,
  Set<DeclarationId> opaqueParameters,
) {
  if (isOpaqueType(type, opaqueParameters)) {
    return;
  }
  if (isReferenceType(type, classes, opaqueParameters: opaqueParameters)) {
    return;
  }
  if (isJsCollectionType(type)) {
    _validateJsCollection(
      type as DeclaredType,
      source,
      classes,
      opaqueParameters,
    );
    return;
  }
  if (type is DeclaredType &&
      type.declaration.library == Uri.parse('dart:typed_data') &&
      !isBinaryType(type)) {
    throw BindingDiagnostic(
      'NAPI_BINARY',
      '${type.declaration.name} is not a supported binary snapshot type; '
          'use Uint8List or ByteBuffer without legacy nullability.',
      source,
    );
  }
  if (type is FunctionTypeBinding) {
    _validateCallback(type, source, direction);
    void payload(BindingType value, ValueDirection valueDirection) {
      _checkValueDirection(
        value,
        source,
        classes,
        valueDirection,
        visited,
        opaqueParameters,
      );
      if (!_isBackendValue(
        value,
        classes,
        valueDirection,
        null,
        opaqueParameters,
      )) {
        throw BindingDiagnostic(
          'NAPI_CALLBACK',
          'Unsupported function payload type.',
          source,
        );
      }
    }

    for (final parameter in type.parameters) {
      payload(
        parameter.type,
        direction == ValueDirection.input
            ? ValueDirection.output
            : ValueDirection.input,
      );
    }
    final result = resultPayload(type.result);
    if (result != null) payload(result, direction);
    return;
  }
  if (type is DeclaredType &&
      type.declaration.library == Uri.parse('dart:core') &&
      type.declaration.name == 'Function') {
    throw BindingDiagnostic(
      'NAPI_CALLBACK',
      'Functions require a typed signature.',
      source,
    );
  }
  if (_valueClassBinding(type, classes) case final binding?) {
    if (!_valueClassArgumentsSupported(
      binding,
      type as DeclaredType,
      opaqueParameters,
    )) {
      throw BindingDiagnostic(
        'NAPI_TYPE',
        'Open value classes require direct opaque type parameters; select a concrete alias for a concrete type.',
        source,
      );
    }
    if (direction == ValueDirection.input && binding.valueConstructor == null) {
      throw BindingDiagnostic(
        'NAPI_VALUE_INPUT',
        '${binding.exportName} has no unambiguous public input constructor.',
        source,
      );
    }
    if (!visited.add((binding, direction))) return;
    if (direction == ValueDirection.input) {
      _validateValueConstructorInputs(binding, classes);
    }
    for (final child in _valueChildren(binding, direction, type)) {
      _checkValueDirection(
        child,
        source,
        classes,
        direction,
        visited,
        opaqueParameters,
      );
    }
  } else if (type is DeclaredType) {
    for (final child in type.typeArguments) {
      _checkValueDirection(
        child,
        source,
        classes,
        direction,
        visited,
        opaqueParameters,
      );
    }
  } else if (type is RecordTypeBinding) {
    for (final child in [...type.positional, ...type.named.values]) {
      _checkValueDirection(
        child,
        source,
        classes,
        direction,
        visited,
        opaqueParameters,
      );
    }
  }
}

bool _isBackendValue(
  BindingType type, [
  List<ClassBinding> classes = const [],
  ValueDirection direction = ValueDirection.output,
  Set<(ClassBinding, ValueDirection)>? seen,
  Set<DeclarationId> opaqueParameters = const {},
]) {
  if (isOpaqueType(type, opaqueParameters) ||
      isJsCollectionType(type) ||
      _isBackendScalar(type) ||
      isBinaryType(type) ||
      isSharedBytesType(type) ||
      isReferenceType(type, classes, opaqueParameters: opaqueParameters)) {
    return true;
  }
  if (type.nullability == TypeNullability.legacy) return false;
  final visited = seen ?? <(ClassBinding, ValueDirection)>{};
  bool child(BindingType value) =>
      _isBackendValue(value, classes, direction, visited, opaqueParameters);
  if (_valueClassBinding(type, classes) case final binding?) {
    if (!_valueClassArgumentsSupported(
      binding,
      type as DeclaredType,
      opaqueParameters,
    )) {
      return false;
    }
    if (direction == ValueDirection.input && binding.valueConstructor == null) {
      return false;
    }
    if (!visited.add((binding, direction))) return true;
    return _valueChildren(binding, direction, type).every(child);
  }
  if (type is FunctionTypeBinding) {
    final argumentDirection = direction == ValueDirection.input
        ? ValueDirection.output
        : ValueDirection.input;
    final result = resultPayload(type.result);
    return type.parameters.every(
          (parameter) => _isBackendValue(
            parameter.type,
            classes,
            argumentDirection,
            visited,
            opaqueParameters,
          ),
        ) &&
        (result == null || child(result));
  }
  if (type is RecordTypeBinding) {
    return type.positional.every(child) && type.named.values.every(child);
  }
  if (type is! DeclaredType || type.semantics != ValueSemantics.structural) {
    return false;
  }
  if (type.declaration == dictionaryDeclaration) {
    return type.typeArguments.length == 1 && child(type.typeArguments.single);
  }
  final name = type.declaration.name;
  return (name == 'List' || name == 'Map') &&
      type.declaration ==
          DeclarationId(
            Uri.parse('dart:core'),
            name,
            kind: DeclarationKind.classType,
          ) &&
      type.typeArguments.length == (name == 'List' ? 1 : 2) &&
      type.typeArguments.every(child);
}

/// Resource views with the same original cleanup target, call shape and defaults
/// share one policy. Generated classifiers reject actual composite objects whose
/// selected views match different policy IDs before exposing or using them.
Map<int, int> resourcePolicies(List<ReferenceClassShape> classes) {
  final payload = DeclarationId(
    Uri.parse('napi:resource-policy'),
    'payload',
    kind: DeclarationKind.typeParameter,
  );
  ReferenceMemberShape contract(ReferenceClassShape shape) {
    final cleanup = shape.cleanup!;
    final parameters = {
      for (final parameter in shape.binding.typeParameters)
        if (parameter.opaque) parameter.declaration: payload,
    };
    if (parameters.isEmpty) return cleanup;
    // Every class payload is the same runtime carrier, independently of its
    // declaration, parameter order, unused slots or class arity.
    return ReferenceMemberShape._(
      cleanup.binding,
      cleanup.kind,
      cleanup.parameters.map((p) => projectOpaqueParameter(p, parameters)),
      cleanup.result == null
          ? null
          : projectOpaqueType(cleanup.result!, parameters),
      isCleanup: true,
    );
  }

  final representatives = <ReferenceClassShape>[];
  final policies = <int, int>{};
  for (final shape in classes) {
    if (shape.cleanup == null) continue;
    final cleanup = contract(shape);
    bool compatible(ReferenceClassShape previous) {
      final other = contract(previous);
      return cleanup.binding.declaration.name ==
              other.binding.declaration.name &&
          (cleanup.binding.callPath ?? cleanup.binding.declaration.name) ==
              (other.binding.callPath ?? other.binding.declaration.name) &&
          referenceMemberAccepts(
            cleanup,
            other,
            classes,
            opaqueInheritance: true,
          ) &&
          referenceMemberAccepts(
            other,
            cleanup,
            classes,
            opaqueInheritance: true,
          ) &&
          referenceMemberDefaultsAccept(cleanup, other) &&
          referenceMemberDefaultsAccept(other, cleanup);
    }

    final previous = representatives.where(compatible).firstOrNull;
    if (previous == null) representatives.add(shape);
    policies[shape.classId] = previous?.classId ?? shape.classId;
  }
  return Map.unmodifiable(policies);
}

bool _referencePositional(ParameterBinding parameter) =>
    parameter.kind == ParameterKind.requiredPositional ||
    parameter.kind == ParameterKind.optionalPositional;

bool referenceMemberDefaultsAccept(
  ReferenceMemberShape actual,
  ReferenceMemberShape expected,
) {
  final positional = actual.parameters.where(_referencePositional).toList();
  final named = {
    for (final p in actual.parameters.where((p) => !_referencePositional(p)))
      p.name: p,
  };
  var position = 0;
  for (final previous in expected.parameters) {
    final parameter = _referencePositional(previous)
        ? positional[position++]
        : named[previous.name]!;
    // Required contracts prescribe no result for omission. If both accept it,
    // the chosen callback must supply the same Dart value, also for undefined.
    if (previous.presence == ParameterPresence.optional &&
        !_sameReferenceDefault(parameter, previous)) {
      return false;
    }
  }
  return true;
}

bool _sameReferenceDefault(ParameterBinding left, ParameterBinding right) =>
    (left.defaultIdentity != null &&
        identical(left.defaultIdentity, right.defaultIdentity)) ||
    parameterDefaultKey(left) == parameterDefaultKey(right);

bool _resourceContainerDefault(BindingType type, List<ClassBinding> classes) {
  if (type.nullability == TypeNullability.legacy) return false;
  bool child(BindingType type) =>
      _isBackendScalar(type) ||
      isReferenceType(type, classes) && !isValueClassType(type, classes) ||
      _resourceContainerDefault(type, classes);
  if (type is RecordTypeBinding) {
    return type.positional.every(child) && type.named.values.every(child);
  }
  if (type is! DeclaredType) return false;
  if (type.declaration == dictionaryDeclaration) {
    return type.typeArguments.length == 1 && child(type.typeArguments.single);
  }
  return type.declaration.library == Uri.parse('dart:core') &&
      ((type.declaration.name == 'List' && type.typeArguments.length == 1) ||
          (type.declaration.name == 'Map' && type.typeArguments.length == 2)) &&
      type.typeArguments.every(child);
}

bool _portableDefaultParameter(
  BindingType type,
  List<ClassBinding> classes, {
  Set<ClassBinding>? seen,
  bool withinValueDefault = false,
  Set<DeclarationId> opaqueParameters = const {},
  bool completeGraph = false,
}) {
  if (_isBackendScalar(type) || isOpaqueType(type, opaqueParameters)) {
    return true;
  }
  if (type.nullability == TypeNullability.legacy) return false;
  final visited = seen ?? <ClassBinding>{};
  bool child(BindingType type) => _portableDefaultParameter(
    type,
    classes,
    seen: visited,
    withinValueDefault: withinValueDefault,
    opaqueParameters: opaqueParameters,
    completeGraph: completeGraph,
  );
  if (type is RecordTypeBinding) {
    return type.positional.every(child) && type.named.values.every(child);
  }
  if (type is! DeclaredType) return false;
  if (type.declaration == dictionaryDeclaration) {
    return type.typeArguments.length == 1 && child(type.typeArguments.single);
  }
  if (type.declaration.library == Uri.parse('dart:core')) {
    return const {'List', 'Map'}.contains(type.declaration.name) &&
        type.typeArguments.every(child);
  }
  final binding = classes
      .where((c) => referenceClassMatches(c, type))
      .firstOrNull;
  if (binding == null || !completeGraph && _isResourceClass(binding, classes)) {
    return false;
  }
  // A class-valued field can hold a resource subtype or composite view,
  // even when its declared class uses value semantics.
  if (!completeGraph &&
      withinValueDefault &&
      classes.any(
        (binding) =>
            binding.classPolicy == ClassPolicy.resource ||
            binding.cleanup != null,
      )) {
    return false;
  }
  if (binding.classPolicy != ClassPolicy.value) {
    return binding.typeParameters.isEmpty && isClosedConcreteType(type);
  }
  if (!_valueClassArgumentsSupported(binding, type, opaqueParameters)) {
    return false;
  }
  if (!visited.add(binding)) return true;
  bool valueField(BindingType type) => _portableDefaultParameter(
    type,
    classes,
    seen: visited,
    withinValueDefault: true,
    opaqueParameters: opaqueParameters,
    completeGraph: completeGraph,
  );
  return _valueChildren(
        binding,
        ValueDirection.input,
        type,
      ).every(valueField) &&
      _valueChildren(binding, ValueDirection.output, type).every(valueField);
}

bool _containsOpaque(BindingType type, Set<DeclarationId> parameters) =>
    isOpaqueType(type, parameters) ||
    switch (type) {
      DeclaredType() => type.typeArguments.any(
        (child) => _containsOpaque(child, parameters),
      ),
      RecordTypeBinding() => [
        ...type.positional,
        ...type.named.values,
      ].any((child) => _containsOpaque(child, parameters)),
      _ => false,
    };

bool _isResourceClass(ClassBinding binding, List<ClassBinding> classes) =>
    binding.classPolicy == ClassPolicy.resource ||
    binding.cleanup != null ||
    classes.any(
      (ancestor) =>
          (ancestor.classPolicy == ClassPolicy.resource ||
              ancestor.cleanup != null) &&
          binding.allSupertypes.any(
            (type) => referenceClassMatches(ancestor, type),
          ),
    );

/// Only the evaluated stored graph determines which default objects need a
/// lifecycle operation. Constructor arguments and exported getters are views.
List<DefaultObjectBinding> defaultResourceObjects(
  ParameterBinding parameter,
  List<ClassBinding> classes,
) => [
  for (final object
      in parameter.defaultObjects ?? const <DefaultObjectBinding>[])
    if (classes.any(
      (binding) =>
          _isResourceClass(binding, classes) &&
          [
            object.type,
            ...object.supertypes,
          ].any((type) => referenceClassMatches(binding, type)),
    ))
      object,
];

bool _defaultResourceHasRuntimeView(
  DefaultObjectBinding object,
  List<ClassBinding> classes,
) => classes.any(
  (binding) =>
      binding.classPolicy != ClassPolicy.value &&
      binding.typeParameters.isEmpty &&
      _isResourceClass(binding, classes) &&
      [
        object.type,
        ...object.supertypes,
      ].any((type) => referenceClassMatches(binding, type)),
);

bool _defaultGraphHasResource(
  ConstantDefault value,
  List<ClassBinding> classes,
) {
  bool child(ConstantDefault value) => _defaultGraphHasResource(value, classes);
  bool resource(DeclaredType type, List<DeclaredType> supertypes) =>
      classes.any(
        (binding) =>
            _isResourceClass(binding, classes) &&
            [
              type,
              ...supertypes,
            ].any((type) => referenceClassMatches(binding, type)),
      );
  return switch (value) {
    ScalarDefault() => false,
    ListDefault(:final elements) => elements.any(child),
    MapDefault(:final entries) => entries.any(
      (entry) => child(entry.$1) || child(entry.$2),
    ),
    RecordDefault(:final positional, :final named) =>
      positional.any(child) || named.values.any(child),
    ObjectDefault(
      :final type,
      :final supertypes,
      :final positional,
      :final named,
    ) =>
      resource(type, supertypes) ||
          positional.any(child) ||
          named.values.any(child),
    NamedObjectDefault(:final type, :final supertypes) => resource(
      type,
      supertypes,
    ),
  };
}

bool _defaultTypeFits(
  BindingType actual,
  BindingType expected,
  List<ClassBinding> classes,
) {
  if (actual is NeverType) {
    return actual.nullability == TypeNullability.nonNullable ||
        expected.nullability == TypeNullability.nullable;
  }
  if (actual is DeclaredType &&
      actual.declaration.library == Uri.parse('dart:core') &&
      actual.declaration.name == 'Null') {
    return expected.nullability == TypeNullability.nullable;
  }
  if (actual.nullability == TypeNullability.nullable &&
      expected.nullability != TypeNullability.nullable) {
    return false;
  }
  if (actual is SafeIntType) return expected is SafeIntType;
  if (actual is RecordTypeBinding && expected is RecordTypeBinding) {
    return actual.positional.length == expected.positional.length &&
        actual.named.length == expected.named.length &&
        actual.positional.indexed.every(
          (e) => _defaultTypeFits(e.$2, expected.positional[e.$1], classes),
        ) &&
        actual.named.entries.every(
          (e) =>
              expected.named.containsKey(e.key) &&
              _defaultTypeFits(e.value, expected.named[e.key]!, classes),
        );
  }
  if (actual is! DeclaredType || expected is! DeclaredType) return false;
  if (expected.declaration == dictionaryDeclaration) {
    return actual.declaration.library == Uri.parse('dart:core') &&
        actual.declaration.name == 'Map' &&
        actual.typeArguments.length == 2 &&
        (constantTypeSource(actual.typeArguments[0]) == 'String' ||
            (actual.typeArguments[0] is NeverType &&
                actual.typeArguments[0].nullability ==
                    TypeNullability.nonNullable)) &&
        _defaultTypeFits(
          actual.typeArguments[1],
          expected.typeArguments.single,
          classes,
        );
  }
  if (actual.declaration != expected.declaration) {
    final binding = classes
        .where((binding) => referenceClassMatches(binding, actual))
        .firstOrNull;
    return binding != null &&
        binding.allSupertypes.any(
          (type) => _defaultTypeFits(type, expected, const []),
        );
  }
  return actual.declaration == expected.declaration &&
      actual.typeArguments.length == expected.typeArguments.length &&
      actual.typeArguments.indexed.every(
        (e) => _defaultTypeFits(e.$2, expected.typeArguments[e.$1], classes),
      );
}

bool _structuralDefaultFits(
  ConstantDefault value,
  BindingType expected,
  List<ClassBinding> classes, {
  bool rootTypeIsAssignable = false,
}) {
  switch (value) {
    case ScalarDefault(:final value):
      if (value == null) {
        return expected.nullability == TypeNullability.nullable ||
            constantTypeSource(expected) == 'Null';
      }
      return expected is SafeIntType
          ? value is int
          : expected is DeclaredType &&
                expected.declaration.library == Uri.parse('dart:core') &&
                switch (expected.declaration.name) {
                  'bool' => value is bool,
                  'String' => value is String,
                  'double' => value is double,
                  _ => false,
                };
    case ListDefault(:final type, :final elements):
      return type is DeclaredType &&
          type.declaration.library == Uri.parse('dart:core') &&
          type.declaration.name == 'List' &&
          type.typeArguments.length == 1 &&
          (rootTypeIsAssignable || _defaultTypeFits(type, expected, classes)) &&
          elements.every(
            (v) =>
                _structuralDefaultFits(v, type.typeArguments.single, classes),
          );
    case MapDefault(:final type, :final entries):
      return type is DeclaredType &&
          type.declaration.library == Uri.parse('dart:core') &&
          type.declaration.name == 'Map' &&
          type.typeArguments.length == 2 &&
          (rootTypeIsAssignable || _defaultTypeFits(type, expected, classes)) &&
          entries.every(
            (e) =>
                _structuralDefaultFits(e.$1, type.typeArguments[0], classes) &&
                _structuralDefaultFits(e.$2, type.typeArguments[1], classes),
          );
    case RecordDefault(:final type, :final positional, :final named):
      return type is RecordTypeBinding &&
          (rootTypeIsAssignable || _defaultTypeFits(type, expected, classes)) &&
          positional.length == type.positional.length &&
          named.length == type.named.length &&
          positional.indexed.every(
            (e) => _structuralDefaultFits(e.$2, type.positional[e.$1], classes),
          ) &&
          named.entries.every(
            (e) =>
                type.named.containsKey(e.key) &&
                _structuralDefaultFits(e.value, type.named[e.key]!, classes),
          );
    case ObjectDefault(:final type, :final supertypes) ||
        NamedObjectDefault(:final type, :final supertypes):
      return expected is DeclaredType &&
          expected.semantics == ValueSemantics.reference &&
          (rootTypeIsAssignable ||
              [
                type,
                ...supertypes,
              ].any((type) => _defaultTypeFits(type, expected, classes)));
  }
}
