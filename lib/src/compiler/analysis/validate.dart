import '../../api/annotation.dart' show ClassPolicy;
import '../ir/model.dart';

final dictionaryDeclaration = DeclarationId(
  Uri.parse('package:napi/src/api/dictionary.dart'),
  'Dictionary',
  kind: DeclarationKind.extensionType,
);

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

/// Common selected class semantics; target-specific ABI names live in lowering.
final class ReferenceMemberShape {
  final MemberBinding binding;
  final ReferenceMemberKind kind;
  final List<ParameterBinding> parameters;
  final BindingType? result;
  bool get isStatic =>
      kind == ReferenceMemberKind.constructor || binding.isStatic;
  String get exportName => binding.exportName ?? binding.declaration.name;
  ReferenceMemberShape._(
    this.binding,
    this.kind,
    Iterable<ParameterBinding> parameters,
    this.result,
  ) : parameters = List.unmodifiable(parameters);
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
  final List<ReferencePropertyShape> prototypeProperties;
  ReferenceClassShape._(
    this.binding,
    this.constructor,
    Iterable<ReferenceMemberShape> members, {
    required this.classId,
    Iterable<int> memberships = const [],
    this.superclassId,
    Iterable<ReferencePropertyShape> prototypeProperties = const [],
  }) : members = List.unmodifiable(members),
       memberships = Set.unmodifiable(memberships),
       prototypeProperties = List.unmodifiable(prototypeProperties);
}

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

/// A finite declaration node; recursive field types refer back by identity.
final class ValueFieldSchema {
  final MemberBinding binding;
  final String name;
  final BindingType type;
  const ValueFieldSchema(this.binding, this.name, this.type);
}

final class ValueInputFieldSchema {
  final ParameterBinding parameter;
  final ValueFieldSchema field;
  const ValueInputFieldSchema(this.parameter, this.field);
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
    if (binding.typeParameters.isNotEmpty) {
      throw BindingDiagnostic(
        'NAPI_GENERIC',
        'Generic value classes are not implemented.',
        binding.source,
      );
    }
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
      validateValueType(type, member.source, referenceClasses: module.classes);
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
        reject('valueConstructor must select one own constructor.');
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
      validateCallParameters(
        constructor.parameters,
        constructor.source,
        referenceClasses: module.classes,
      );
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
        if (matches.length != 1) {
          reject(
            'No unique selected field/getter for constructor parameter ${parameter.name}; configure valueFields.',
            parameter.source,
          );
        }
        final field = matches.single;
        if (!names.add(field.name)) {
          reject(
            'Duplicate value input property ${field.name}.',
            parameter.source,
          );
        }
        inputs.add(ValueInputFieldSchema(parameter, field));
      }
    } else if (binding.valueFields.isNotEmpty) {
      reject('valueFields requires valueConstructor.');
    }
    result.add(ValueClassSchema(binding, constructor, fields, inputs));
  }
  return List.unmodifiable(result);
}

final _identifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
const _reserved = {
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
    checkExport(binding.declaration, binding.exportName, binding.source);
    _checkTypeParameters(binding.typeParameters, binding.source);
    if (binding.supertype case final type?) {
      _checkType(type, binding.source);
    }
    for (final type in [...binding.interfaces, ...binding.mixins]) {
      _checkType(type, binding.source);
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
              _reserved.contains(segment),
        )) {
      reject('NAPI_NAME', 'Expected a public Dart function call path.');
    }
    if (!_identifier.hasMatch(function.exportName) ||
        _reserved.contains(function.exportName) ||
        // These are valid Dart identifiers and declaration parameter names,
        // but cannot be local bindings in an unaliased strict-mode ESM import.
        const {'eval', 'arguments'}.contains(function.exportName) ||
        function.exportName == 'then' ||
        function.exportName.startsWith('wasm_')) {
      reject('NAPI_NAME', 'Export name is not a supported public identifier.');
    }
    if (function.typeParameters.isNotEmpty) {
      reject(
        'NAPI_GENERIC',
        'Generic functions require a generic-capable backend.',
      );
    }
    if (function.isAsync || function.isGenerator) {
      reject('NAPI_TYPE', 'Async and generator functions are not supported.');
    }
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
    );
    validateValueType(
      function.result,
      function.source,
      referenceClasses: module.classes,
    );
  }
  return ValidatedModule._(declarations.bindings, classes, values);
}

/// The shared synchronous reference-class slice, without target ABI choices.
List<ReferenceClassShape> validateReferenceClasses(BindingModule module) {
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
    if (binding.classPolicy != ClassPolicy.reference) {
      reject('NAPI_CLASS', 'A reference class policy is required.');
    }
    if (binding.typeParameters.isNotEmpty) {
      reject(
        'NAPI_GENERIC',
        'Generic class specialization is not implemented.',
      );
    }
    ReferenceMemberShape? constructor;
    final members = <ReferenceMemberShape>[];
    ReferenceMemberShape call(
      MemberBinding member,
      ReferenceMemberKind kind,
      List<ParameterBinding> parameters,
      BindingType? type,
    ) {
      validateCallParameters(
        parameters,
        member.source,
        referenceClasses: module.classes,
      );
      if (type != null && type is! VoidType) {
        validateValueType(
          type,
          member.source,
          referenceClasses: module.classes,
        );
      }
      return ReferenceMemberShape._(
        member,
        kind,
        parameters,
        type is VoidType ? null : type,
      );
    }

    for (final member in binding.members) {
      if (member.selection == MemberSelection.excluded) continue;
      if (member.typeParameters.isNotEmpty) {
        reject(
          'NAPI_GENERIC',
          'Generic members are not implemented.',
          member.source,
        );
      }
      if (member.isAsync || member.isGenerator) {
        reject(
          'NAPI_TYPE',
          'Only synchronous members are implemented.',
          member.source,
        );
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
              ParameterBinding('value', type, source: member.source),
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
  return _referenceHierarchy(result);
}

List<ReferenceClassShape> _referenceHierarchy(
  List<ReferenceClassShape> classes,
) {
  final ids = {
    for (final shape in classes) shape.binding.declaration: shape.classId,
  };
  final memberships = <int, Set<int>>{};
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
    final declarations = <DeclarationId>{
      ...binding.allSupertypes,
      ...binding.superclassChain,
      // These edges also support hand-written IR without resolved ancestors.
      if (binding.supertype case DeclaredType(:final declaration)) declaration,
      for (final type in [...binding.interfaces, ...binding.mixins])
        if (type case DeclaredType(:final declaration)) declaration,
    };
    for (final declaration in declarations) {
      if (ids[declaration] case final parent?) {
        result.addAll(ancestors(parent));
      }
    }
    visiting.remove(id);
    return memberships[id] = result;
  }

  int? superclass(ClassBinding binding) {
    for (final declaration in binding.superclassChain) {
      if (ids[declaration] case final parent?) return parent;
    }
    if (binding.supertype case DeclaredType(:final declaration)) {
      return ids[declaration];
    }
    return null;
  }

  final shapes = [
    for (final shape in classes)
      ReferenceClassShape._(
        shape.binding,
        shape.constructor,
        shape.members,
        classId: shape.classId,
        memberships: ancestors(shape.classId),
        superclassId: superclass(shape.binding),
      ),
  ];
  final effective = <int, Map<String, ReferencePropertyShape>>{};
  final order = referenceClassOrder(shapes);
  ReferenceMemberShape member(ReferenceMemberRef ref) =>
      classes[ref.classId].members[ref.memberIndex];
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
      for (final (index, selected) in classes[ancestor].members.indexed) {
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
                (ref) => _referenceMemberAccepts(
                  member(candidate),
                  member(ref),
                  ids,
                  memberships,
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

bool _referenceMemberAccepts(
  ReferenceMemberShape implementation,
  ReferenceMemberShape contract,
  Map<DeclarationId, int> ids,
  Map<int, Set<int>> memberships,
) {
  bool subtype(BindingType child, BindingType parent) =>
      _referenceSubtype(child, parent, ids, memberships);
  final output = implementation.result;
  final requiredOutput = contract.result;
  if ((output == null) != (requiredOutput == null) ||
      (output != null && !subtype(output, requiredOutput!))) {
    return false;
  }
  bool positional(ParameterBinding p) =>
      p.kind == ParameterKind.requiredPositional ||
      p.kind == ParameterKind.optionalPositional;
  final actual = implementation.parameters.where(positional).toList();
  final expected = contract.parameters.where(positional).toList();
  if (actual.length < expected.length) return false;
  for (final (index, parameter) in actual.indexed) {
    if (index >= expected.length) {
      if (parameter.presence != ParameterPresence.optional) return false;
      continue;
    }
    final previous = expected[index];
    if ((previous.presence == ParameterPresence.optional &&
            parameter.presence != ParameterPresence.optional) ||
        !subtype(previous.type, parameter.type)) {
      return false;
    }
  }
  final actualNamed = {
    for (final p in implementation.parameters.where((p) => !positional(p)))
      p.name: p,
  };
  final expectedNamed = {
    for (final p in contract.parameters.where((p) => !positional(p))) p.name: p,
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
        (previous.presence == ParameterPresence.optional &&
            parameter.presence != ParameterPresence.optional) ||
        !subtype(previous.type, parameter.type)) {
      return false;
    }
  }
  return actualNamed.values.every(
    (p) =>
        expectedNamed.containsKey(p.name) ||
        p.presence == ParameterPresence.optional,
  );
}

bool _referenceSubtype(
  BindingType child,
  BindingType parent,
  Map<DeclarationId, int> ids,
  Map<int, Set<int>> memberships,
) {
  if (child.nullability == TypeNullability.nullable &&
      parent.nullability != TypeNullability.nullable) {
    return false;
  }
  if (child is SafeIntType && parent is SafeIntType) return true;
  if (child is DeclaredType && parent is DeclaredType) {
    if (child.declaration != parent.declaration) {
      final childId = ids[child.declaration];
      final parentId = ids[parent.declaration];
      return childId != null &&
          parentId != null &&
          memberships[childId]!.contains(parentId);
    }
    return child.typeArguments.length == parent.typeArguments.length &&
        child.typeArguments.indexed.every(
          (entry) => _referenceSubtype(
            entry.$2,
            parent.typeArguments[entry.$1],
            ids,
            memberships,
          ),
        );
  }
  if (child is RecordTypeBinding && parent is RecordTypeBinding) {
    return child.positional.length == parent.positional.length &&
        child.named.length == parent.named.length &&
        child.positional.indexed.every(
          (entry) => _referenceSubtype(
            entry.$2,
            parent.positional[entry.$1],
            ids,
            memberships,
          ),
        ) &&
        child.named.entries.every(
          (entry) =>
              parent.named.containsKey(entry.key) &&
              _referenceSubtype(
                entry.value,
                parent.named[entry.key]!,
                ids,
                memberships,
              ),
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
      _reserved.contains(name) ||
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

/// Only direct references to selected public classes have a runtime mapping.
bool isReferenceType(BindingType type, List<ClassBinding> classes) =>
    type is DeclaredType &&
    type.nullability != TypeNullability.legacy &&
    type.typeArguments.isEmpty &&
    type.semantics == ValueSemantics.reference &&
    classes.any(
      (binding) =>
          binding.classPolicy == ClassPolicy.reference &&
          binding.declaration == type.declaration &&
          binding.typeParameters.isEmpty,
    );

/// Scalar/structural values and selected reference leaves share one capability
/// check. Reference leaves must name a selected, non-generic public class.
void validateValueType(
  BindingType type,
  SourceLocation source, {
  List<ClassBinding> referenceClasses = const [],
  ValueDirection direction = ValueDirection.output,
}) {
  _checkValueDirection(
    type,
    source,
    referenceClasses,
    direction,
    <DeclarationId>{},
  );
  if (!_isBackendValue(type, referenceClasses, direction)) {
    throw BindingDiagnostic(
      'NAPI_TYPE',
      'No scalar, structural or selected class reference conversion for this type.',
      source,
    );
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
  List<ClassBinding> referenceClasses = const [],
}) {
  var optionalPositional = false;
  var named = false;
  for (final parameter in parameters) {
    void reject(String code, String message) =>
        throw BindingDiagnostic(code, message, parameter.source ?? source);
    if (!_identifier.hasMatch(parameter.name) ||
        _reserved.contains(parameter.name)) {
      reject('NAPI_PARAMETER', 'Unsupported backend parameter name.');
    }
    final optional =
        parameter.kind == ParameterKind.optionalPositional ||
        parameter.kind == ParameterKind.optionalNamed;
    if (parameter.presence !=
        (optional ? ParameterPresence.optional : ParameterPresence.required)) {
      reject(
        'NAPI_PRESENCE',
        'Parameter presence must match its Dart kind. Opaque presence '
            'requires the opaque conversion engine (#125).',
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
    if (!scalarOnly) {
      validateValueType(
        parameter.type,
        parameter.source ?? source,
        referenceClasses: referenceClasses,
        direction: ValueDirection.input,
      );
    } else if (!_isBackendScalar(parameter.type) &&
        !isReferenceType(parameter.type, referenceClasses)) {
      reject('NAPI_TYPE', 'No scalar conversion for this type.');
    }
    if (!optional && parameter.hasDefault) {
      reject('NAPI_DEFAULT', 'Required parameters cannot have defaults.');
    }
    if (optional) validateParameterDefault(parameter, source);
  }
}

/// Validate defaults shared by the scalar native and Wasm backends.
void validateParameterDefault(
  ParameterBinding parameter,
  SourceLocation source,
) {
  final value = parameter.defaultValue?.value;
  final type = parameter.type;
  if (!_isBackendScalar(type) &&
      ((parameter.hasDefault && parameter.defaultValue == null) ||
          value != null)) {
    throw BindingDiagnostic(
      'NAPI_DEFAULT',
      type.semantics == ValueSemantics.reference
          ? 'Non-null reference defaults are not supported; a nullable reference parameter may use a null default.'
          : 'Non-null structural defaults are not supported; a nullable structural parameter may use a null default.',
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

bool isValueClassType(BindingType type, List<ClassBinding> classes) =>
    type is DeclaredType &&
    type.nullability != TypeNullability.legacy &&
    type.semantics == ValueSemantics.reference &&
    type.typeArguments.isEmpty &&
    classes.any(
      (c) =>
          c.classPolicy == ClassPolicy.value &&
          c.declaration == type.declaration &&
          c.typeParameters.isEmpty,
    );

Iterable<BindingType> _valueChildren(
  ClassBinding binding,
  ValueDirection direction,
) {
  if (direction == ValueDirection.input) {
    final constructor = binding.members
        .where((m) => m.declaration == binding.valueConstructor)
        .firstOrNull;
    return constructor?.parameters.map((p) => p.type) ?? const [];
  }
  return binding.members
      .where(
        (m) =>
            m.selection != MemberSelection.excluded &&
            !m.isStatic &&
            (m.kind == MemberKind.field || m.kind == MemberKind.getter),
      )
      .map(
        (m) =>
            (m.kind == MemberKind.field ? m.type : m.result) ??
            const DynamicType(),
      );
}

void _checkValueDirection(
  BindingType type,
  SourceLocation source,
  List<ClassBinding> classes,
  ValueDirection direction,
  Set<DeclarationId> visited,
) {
  if (isValueClassType(type, classes)) {
    final binding = classes.firstWhere(
      (c) => c.declaration == (type as DeclaredType).declaration,
    );
    if (direction == ValueDirection.input && binding.valueConstructor == null) {
      throw BindingDiagnostic(
        'NAPI_VALUE_INPUT',
        '${binding.exportName} is output-only; configure valueConstructor for input.',
        source,
      );
    }
    if (!visited.add(binding.declaration)) return;
    for (final child in _valueChildren(binding, direction)) {
      _checkValueDirection(child, source, classes, direction, visited);
    }
  } else if (type is DeclaredType) {
    for (final child in type.typeArguments) {
      _checkValueDirection(child, source, classes, direction, visited);
    }
  } else if (type is RecordTypeBinding) {
    for (final child in [...type.positional, ...type.named.values]) {
      _checkValueDirection(child, source, classes, direction, visited);
    }
  }
}

bool _isBackendValue(
  BindingType type, [
  List<ClassBinding> classes = const [],
  ValueDirection direction = ValueDirection.output,
  Set<DeclarationId>? seen,
]) {
  if (_isBackendScalar(type) || isReferenceType(type, classes)) return true;
  if (type.nullability == TypeNullability.legacy) return false;
  final visited = seen ?? <DeclarationId>{};
  bool child(BindingType value) =>
      _isBackendValue(value, classes, direction, visited);
  if (isValueClassType(type, classes)) {
    final binding = classes.firstWhere(
      (c) => c.declaration == (type as DeclaredType).declaration,
    );
    if (direction == ValueDirection.input && binding.valueConstructor == null) {
      return false;
    }
    if (!visited.add(binding.declaration)) return true;
    return _valueChildren(binding, direction).every(child);
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
