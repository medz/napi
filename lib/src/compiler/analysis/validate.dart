import '../../api/annotation.dart' show ClassPolicy;
import '../ir/model.dart';

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
  const ValidatedModule._(this.bindings);
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
  if (module.classes.isNotEmpty) {
    throw BindingDiagnostic(
      'NAPI_CLASS',
      'Class declarations require a class-capable backend; '
          'the current backend only generates scalar functions.',
      module.classes.first.source,
    );
  }
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
    var optionalPositional = false;
    var named = false;
    for (final parameter in function.parameters) {
      if (!_identifier.hasMatch(parameter.name) ||
          _reserved.contains(parameter.name)) {
        reject('NAPI_PARAMETER', 'Unsupported backend parameter name.');
      }
      final optional =
          parameter.kind == ParameterKind.optionalPositional ||
          parameter.kind == ParameterKind.optionalNamed;
      if (parameter.presence !=
          (optional
              ? ParameterPresence.optional
              : ParameterPresence.required)) {
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
      if (!_isBackendValue(parameter.type)) {
        reject(
          'NAPI_TYPE',
          'No conversion engine for this '
              '${parameter.type.semantics.name} type and nullability.',
        );
      }
      if (!optional && parameter.hasDefault) {
        reject('NAPI_DEFAULT', 'Required parameters cannot have defaults.');
      }
      if (optional) _checkDefault(parameter, function.source);
    }
    if (!_isBackendValue(function.result)) {
      reject(
        'NAPI_TYPE',
        'No scalar or structural conversion engine for this result.',
      );
    }
  }
  return ValidatedModule._(declarations.bindings);
}

void _checkDefault(ParameterBinding parameter, SourceLocation source) {
  final value = parameter.defaultValue?.value;
  final type = parameter.type;
  if (!_isBackendScalar(type) &&
      ((parameter.hasDefault && parameter.defaultValue == null) ||
          value != null)) {
    throw BindingDiagnostic(
      'NAPI_DEFAULT',
      'Non-null List and record defaults are not supported; '
          'a nullable structural parameter may use a null default.',
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

bool _isBackendValue(BindingType type) {
  if (_isBackendScalar(type)) return true;
  if (type.nullability == TypeNullability.legacy) return false;
  if (type is RecordTypeBinding) {
    return type.positional.every(_isBackendValue) &&
        type.named.values.every(_isBackendValue);
  }
  return type is DeclaredType &&
      type.semantics == ValueSemantics.structural &&
      type.declaration.library == Uri.parse('dart:core') &&
      type.declaration.kind == DeclarationKind.classType &&
      type.declaration.owner == null &&
      type.declaration.name == 'List' &&
      type.typeArguments.length == 1 &&
      _isBackendValue(type.typeArguments.single);
}
