import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart' as a;
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart' as a;
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:path/path.dart' as p;

import '../analysis/validate.dart';
import '../ir/model.dart';
import 'wasm_analysis.dart';

/// Source annotations and future external bindings meet at this boundary.
abstract interface class BindingFrontend {
  Future<BindingModule> read(Uri library);
}

/// Resolves the selected library's public export namespace, including reexports.
///
/// Analyzer elements and types are confined to this frontend. The result is
/// descriptive metadata; backend capability checks happen separately at build.
final class AnnotationFrontend implements BindingFrontend {
  final String? sdkPath;
  final String? packagesPath;
  const AnnotationFrontend({this.sdkPath, this.packagesPath});

  @override
  Future<BindingModule> read(Uri library) async {
    if (library.scheme != 'file' || !File.fromUri(library).existsSync()) {
      throw BindingDiagnostic(
        'NAPI_INPUT',
        'Provide an existing file library.',
      );
    }
    final path = p.normalize(File.fromUri(library).absolute.path);
    final entry = File(path).uri;
    final contexts = createWasmAnalysisContext(
      path: path,
      sdkPath: sdkPath,
      packageConfigFile: packagesPath == null
          ? null
          : p.normalize(File(packagesPath!).absolute.path),
    );
    try {
      final session = contexts.contextFor(path).currentSession;
      final result = await session.getResolvedLibrary(path);
      if (result is! ResolvedLibraryResult) {
        throw BindingDiagnostic('NAPI_INPUT', 'Input must be a Dart library.');
      }
      final annotation = await session.getLibraryByUri(
        'package:napi/src/api/annotation.dart',
      );
      if (annotation is! LibraryElementResult ||
          annotation.element.getClass('NAPI') == null) {
        throw BindingDiagnostic(
          'NAPI_ANNOTATION',
          'Cannot resolve package:napi. Run dart pub get for the input package.',
        );
      }
      return await _Reader(
        entry,
        annotation.element.getClass('NAPI')!,
      ).read(result);
    } finally {
      await contexts.dispose();
    }
  }
}

final class _Configuration {
  final String? name;
  final bool exclude;
  final bool bigint;
  const _Configuration(this.name, this.exclude, this.bigint);
}

final class _Reader {
  final Uri entry;
  final a.ClassElement annotationClass;
  final _libraries = <a.LibraryElement, ResolvedLibraryResult>{};
  final _documentation = <a.Element, String>{};
  final _typeParameterIds = <a.TypeParameterElement, DeclarationId>{};
  _Reader(this.entry, this.annotationClass);

  Future<BindingModule> read(ResolvedLibraryResult root) async {
    await _load(root.element, result: root);
    final candidates = root.element.exportNamespace.definedNames2.entries
        .where((e) => e.value is! a.MultiplyDefinedElement)
        .toList();
    // Source order is deterministic within an origin; reexports use origin URI.
    candidates.sort((x, y) {
      final uri = x.value.library!.uri.toString().compareTo(
        y.value.library!.uri.toString(),
      );
      return uri != 0
          ? uri
          : x.value.firstFragment.offset.compareTo(
              y.value.firstFragment.offset,
            );
    });
    final functions = <FunctionBinding>[];
    final classes = <ClassBinding>[];
    final seen = <a.Element>{};
    for (final candidate in candidates) {
      final element = candidate.value;
      if (!seen.add(element)) continue;
      final config = _config(element);
      if (config == null) continue;
      await _load(element.library!);
      if (config.exclude) {
        _reject(
          element,
          'NAPI_PLACEMENT',
          'exclude is only valid on a class member.',
        );
      }
      if (element is a.TopLevelFunctionElement) {
        functions.add(_function(element, candidate.key, config));
      } else if (element is a.ClassElement) {
        classes.add(_class(element, candidate.key, config));
      } else {
        _reject(
          element,
          'NAPI_PLACEMENT',
          '@NAPI() selects functions and classes.',
        );
      }
    }
    final module = BindingModule(
      source: entry,
      functions: functions,
      classes: classes,
    );
    validateDeclarations(module);
    return module;
  }

  Future<void> _load(
    a.LibraryElement library, {
    ResolvedLibraryResult? result,
  }) async {
    if (_libraries.containsKey(library)) return;
    final resolved =
        result ?? await library.session.getResolvedLibraryByElement(library);
    if (resolved is! ResolvedLibraryResult) {
      throw BindingDiagnostic('NAPI_RESOLVE', 'Cannot resolve ${library.uri}.');
    }
    _libraries[library] = resolved;
    for (final unit in resolved.units) {
      for (final diagnostic in unit.diagnostics) {
        if (diagnostic.severity == Severity.error) {
          final location = unit.lineInfo.getLocation(diagnostic.offset);
          throw BindingDiagnostic(
            'NAPI_DART',
            diagnostic.message,
            SourceLocation(
              File(unit.path).uri,
              diagnostic.offset,
              diagnostic.length,
              line: location.lineNumber,
              column: location.columnNumber,
            ),
          );
        }
      }
      unit.unit.accept(_AnnotationVisitor(this));
    }
  }

  bool _isAnnotation(a.Element? element) =>
      element is a.ConstructorElement &&
      element.enclosingElement == annotationClass;

  bool _isAnnotationValue(a.Element? element) =>
      _isAnnotation(element) ||
      (element is a.GetterElement &&
          element.variable.computeConstantValue()?.type?.element ==
              annotationClass);

  _Configuration? _config(a.Element element) {
    final matches = element.metadata.annotations
        .where(
          (m) =>
              _isAnnotation(m.element) ||
              m.computeConstantValue()?.type?.element == annotationClass,
        )
        .toList();
    if (matches.isEmpty) return null;
    if (matches.length != 1) {
      _reject(
        element,
        'NAPI_SELECTION',
        'Use one @NAPI annotation per declaration.',
      );
    }
    if (!_isAnnotation(matches.single.element)) {
      _reject(
        element,
        'NAPI_ANNOTATION',
        'Use the NAPI constructor annotation, not a constant-valued alias.',
      );
    }
    final value = matches.single.computeConstantValue();
    if (value == null || value.type?.element != annotationClass) {
      _reject(
        element,
        'NAPI_ANNOTATION',
        'NAPI configuration must be a resolved constant.',
      );
    }
    final name = value.getField('name')?.toStringValue();
    final exclude = value.getField('exclude')?.toBoolValue();
    final bigint = value.getField('bigint')?.toBoolValue();
    if (exclude == null ||
        bigint == null ||
        (name == null && value.getField('name')?.isNull != true)) {
      _reject(
        element,
        'NAPI_ANNOTATION',
        'NAPI configuration must have a known constant value.',
      );
    }
    if (exclude && name != null) {
      _reject(
        element,
        'NAPI_SELECTION',
        'name and exclude cannot be combined.',
      );
    }
    return _Configuration(name, exclude, bigint);
  }

  FunctionBinding _function(
    a.TopLevelFunctionElement element,
    String path,
    _Configuration config,
  ) => FunctionBinding(
    declaration: _id(element),
    exportName: config.name ?? path,
    source: _source(element),
    exportSurface: entry,
    callPath: path,
    parameters: element.formalParameters.indexed.map(
      (p) => _parameter(p.$2, owner: _id(element), path: 'parameter:${p.$1}'),
    ),
    result: _type(element.returnType, owner: _id(element), path: 'return'),
    typeParameters: element.typeParameters.map(_typeParameter),
    documentation: element.documentationComment ?? _documentation[element],
    isExternal: element.isExternal,
    isAsync: element.firstFragment.isAsynchronous,
    isGenerator: element.firstFragment.isGenerator,
    bigint: config.bigint,
  );

  ClassBinding _class(
    a.ClassElement element,
    String path,
    _Configuration config,
  ) {
    final members = <a.Element>[
      ...element.constructors,
      ...element.fields.where((e) => !e.isOriginGetterSetter),
      ...element.methods,
      ...element.getters.where((e) => !e.isOriginVariable),
      ...element.setters.where((e) => !e.isOriginVariable),
    ]..sort((x, y) => x.firstFragment.offset.compareTo(y.firstFragment.offset));
    return ClassBinding(
      declaration: _id(element),
      exportName: config.name ?? path,
      source: _source(element),
      exportSurface: entry,
      callPath: path,
      documentation: element.documentationComment ?? _documentation[element],
      typeParameters: element.typeParameters.map(_typeParameter),
      members: members.where((e) => e.isPublic).map(_member),
      isAbstract: element.isAbstract,
      isSealed: element.isSealed,
      isBase: element.isBase,
      isInterface: element.isInterface,
      isFinal: element.isFinal,
      isMixinClass: element.isMixinClass,
      supertype: element.supertype == null
          ? null
          : _type(element.supertype!, owner: _id(element), path: 'supertype'),
      interfaces: element.interfaces.indexed.map(
        (t) => _type(t.$2, owner: _id(element), path: 'interface:${t.$1}'),
      ),
      mixins: element.mixins.indexed.map(
        (t) => _type(t.$2, owner: _id(element), path: 'mixin:${t.$1}'),
      ),
    );
  }

  MemberBinding _member(a.Element element) {
    final config = _config(element);
    final kind = switch (element) {
      a.ConstructorElement() => MemberKind.constructor,
      a.MethodElement() => MemberKind.method,
      a.GetterElement() => MemberKind.getter,
      a.SetterElement() => MemberKind.setter,
      _ => MemberKind.field,
    };
    final executable = element is a.ExecutableElement ? element : null;
    final field = element is a.FieldElement ? element : null;
    final constructor = element is a.ConstructorElement ? element : null;
    final node = _node(element);
    return MemberBinding(
      declaration: _id(element),
      source: _source(element),
      kind: kind,
      selection: config?.exclude == true
          ? MemberSelection.excluded
          : config != null
          ? MemberSelection.explicit
          : MemberSelection.implicit,
      exportName:
          config?.name ?? (constructor?.name == 'new' ? null : element.name),
      hasExplicitExportName: config?.name != null,
      documentation: element.documentationComment ?? _documentation[element],
      parameters:
          executable?.formalParameters.indexed.map(
            (p) => _parameter(
              p.$2,
              owner: _id(element),
              path: 'parameter:${p.$1}',
            ),
          ) ??
          const [],
      result: executable == null
          ? null
          : _type(executable.returnType, owner: _id(element), path: 'return'),
      type: field == null ? null : _type(field.type, owner: _id(element)),
      typeParameters:
          executable?.typeParameters.map(_typeParameter) ?? const [],
      callPath: element.name,
      isStatic: executable?.isStatic ?? field?.isStatic ?? false,
      isFactory: constructor?.isFactory ?? false,
      isConst: constructor?.isConst ?? field?.isConst ?? false,
      isAbstract: executable?.isAbstract ?? field?.isAbstract ?? false,
      isExternal: executable?.isExternal ?? field?.isExternal ?? false,
      isFinal: field?.isFinal ?? false,
      isLate: field?.isLate ?? false,
      isSynthetic: constructor != null && !constructor.isOriginDeclaration,
      isAsync: executable?.firstFragment.isAsynchronous ?? false,
      isGenerator: executable?.firstFragment.isGenerator ?? false,
      isOperator: element is a.MethodElement && element.isOperator,
      initializerSource: node is VariableDeclaration
          ? node.initializer?.toSource()
          : null,
    );
  }

  ParameterBinding _parameter(
    a.FormalParameterElement element, {
    DeclarationId? owner,
    String path = 'parameter',
  }) => ParameterBinding(
    element.name ?? '',
    _type(element.type, owner: owner, path: path),
    kind: element.isRequiredNamed
        ? ParameterKind.requiredNamed
        : element.isOptionalNamed
        ? ParameterKind.optionalNamed
        : element.isOptionalPositional
        ? ParameterKind.optionalPositional
        : ParameterKind.requiredPositional,
    defaultSource: element.defaultValueCode,
    defaultValue: _scalarDefault(element),
    hasDefault: element.hasDefaultValue,
    source: element.firstFragment.libraryFragment == null
        ? null
        : _source(element),
    documentation: element.documentationComment ?? _documentation[element],
    isInitializingFormal: element is a.FieldFormalParameterElement,
    isSuperFormal: element is a.SuperFormalParameterElement,
    isCovariant: element.isCovariant,
  );

  ScalarDefault? _scalarDefault(a.FormalParameterElement element) {
    if (!element.hasDefaultValue) return null;
    final value = element.computeConstantValue();
    if (value == null) return null;
    if (value.isNull) return const ScalarDefault(null);
    final scalar =
        value.toBoolValue() ??
        value.toIntValue() ??
        value.toDoubleValue() ??
        value.toStringValue();
    return scalar == null ? null : ScalarDefault(scalar);
  }

  TypeParameterBinding _typeParameter(a.TypeParameterElement element) =>
      TypeParameterBinding(
        declaration: _id(element),
        source: element.firstFragment.libraryFragment == null
            ? null
            : _source(element),
        bound: element.bound == null
            ? null
            : _type(element.bound!, owner: _id(element), path: 'bound'),
        documentation: element.documentationComment ?? _documentation[element],
      );

  BindingType _type(
    a.DartType type, {
    DeclarationId? owner,
    String path = 'type',
  }) {
    final nullable = type.nullabilitySuffix == NullabilitySuffix.question
        ? TypeNullability.nullable
        : TypeNullability.nonNullable;
    final alias = type.alias == null
        ? null
        : TypeAliasBinding(
            declaration: _id(type.alias!.element),
            typeArguments: type.alias!.typeArguments.indexed.map(
              (t) => _type(t.$2, owner: owner, path: '$path.alias:${t.$1}'),
            ),
          );
    if (type.isDartCoreInt) {
      return SafeIntType(nullability: nullable, alias: alias);
    }
    if (type is a.InterfaceType) {
      final semantics =
          type.isDartCoreList || type.isDartCoreMap || type.isDartCoreSet
          ? ValueSemantics.structural
          : type.isDartCoreBool ||
                type.isDartCoreDouble ||
                type.isDartCoreString ||
                (type.element.library.uri == Uri.parse('dart:core') &&
                    type.element.name == 'BigInt')
          ? ValueSemantics.scalar
          : ValueSemantics.reference;
      return DeclaredType(
        _id(type.element),
        semantics,
        typeArguments: type.typeArguments.indexed.map(
          (t) => _type(t.$2, owner: owner, path: '$path.argument:${t.$1}'),
        ),
        nullability: nullable,
        alias: alias,
      );
    }
    if (type is a.TypeParameterType) {
      return TypeParameterType(
        _id(type.element),
        nullability: nullable,
        alias: alias,
      );
    }
    if (type is a.FunctionType) {
      final functionOwner = DeclarationId(
        owner?.library ?? entry,
        '@$path',
        owner: owner,
      );
      for (final item in type.typeParameters.indexed) {
        final parameter = item.$2;
        _typeParameterIds[parameter] = DeclarationId(
          functionOwner.library,
          parameter.name!,
          owner: functionOwner,
          kind: DeclarationKind.typeParameter,
          slot: parameter.name == '_' ? item.$1 : null,
        );
      }
      return FunctionTypeBinding(
        result: _type(type.returnType, owner: functionOwner, path: 'return'),
        parameters: type.formalParameters.indexed.map(
          (p) =>
              _parameter(p.$2, owner: functionOwner, path: 'parameter:${p.$1}'),
        ),
        typeParameters: type.typeParameters.map(_typeParameter),
        nullability: nullable,
        alias: alias,
      );
    }
    if (type is a.RecordType) {
      return RecordTypeBinding(
        positional: type.positionalFields.indexed.map(
          (f) =>
              _type(f.$2.type, owner: owner, path: '$path.positional:${f.$1}'),
        ),
        named: {
          for (final f in type.namedFields)
            f.name: _type(f.type, owner: owner, path: '$path.named:${f.name}'),
        },
        nullability: nullable,
        alias: alias,
      );
    }
    if (type is a.DynamicType) {
      return DynamicType(nullability: nullable, alias: alias);
    }
    if (type is a.VoidType) {
      return VoidType(nullability: nullable, alias: alias);
    }
    if (type is a.NeverType) {
      return NeverType(nullability: nullable, alias: alias);
    }
    throw BindingDiagnostic(
      'NAPI_TYPE_METADATA',
      'Cannot normalize resolved Dart type $type.',
    );
  }

  DeclarationId _id(a.Element element) {
    if (element is a.TypeParameterElement &&
        _typeParameterIds.containsKey(element)) {
      return _typeParameterIds[element]!;
    }
    final owner = element.enclosingElement;
    return DeclarationId(
      element.library?.uri ?? entry,
      element.name ?? '@${element.firstFragment.offset}',
      owner: owner == null || owner is a.LibraryElement ? null : _id(owner),
      slot:
          element is a.TypeParameterElement &&
              element.name == '_' &&
              owner is a.TypeParameterizedElement
          ? owner.typeParameters.indexOf(element)
          : null,
      kind: switch (element) {
        a.ClassElement() => DeclarationKind.classType,
        a.EnumElement() => DeclarationKind.enumType,
        a.MixinElement() => DeclarationKind.mixinType,
        a.ExtensionTypeElement() => DeclarationKind.extensionType,
        a.ConstructorElement() => DeclarationKind.constructor,
        a.MethodElement() => DeclarationKind.method,
        a.GetterElement() => DeclarationKind.getter,
        a.SetterElement() => DeclarationKind.setter,
        a.FieldElement() => DeclarationKind.field,
        a.TypeParameterElement() => DeclarationKind.typeParameter,
        a.TypeAliasElement() => DeclarationKind.typedefType,
        _ => DeclarationKind.function,
      },
    );
  }

  AstNode? _node(a.Element element) => _libraries[element.library]
      ?.getFragmentDeclaration(element.firstFragment)
      ?.node;

  SourceLocation _source(a.Element element) {
    if (element is a.ConstructorElement && !element.isOriginDeclaration) {
      return _source(element.enclosingElement);
    }
    final fragment = element.firstFragment;
    final unit = fragment.libraryFragment;
    final node = element is a.ConstructorElement && fragment.nameOffset == null
        ? _node(element)
        : null;
    final constructorName = node is ConstructorDeclaration
        ? node.typeName
        : null;
    final rawOffset =
        constructorName?.offset ?? fragment.nameOffset ?? fragment.offset;
    final offset = rawOffset < 0 ? 0 : rawOffset;
    final position = unit?.lineInfo.getLocation(offset);
    final source = unit?.source ?? element.library?.firstFragment.source;
    return SourceLocation(
      source == null ? entry : File(source.fullName).uri,
      offset,
      constructorName?.length ?? element.name?.length ?? 0,
      line: position?.lineNumber,
      column: position?.columnNumber,
    );
  }

  Never _reject(a.Element element, String code, String message) =>
      throw BindingDiagnostic(code, message, _source(element));
}

final class _AnnotationVisitor extends RecursiveAstVisitor<void> {
  final _Reader reader;
  _AnnotationVisitor(this.reader);
  @override
  void visitTypeParameter(TypeParameter node) {
    final element = node.declaredFragment?.element;
    final comment = node.documentationComment;
    if (element != null && comment != null) {
      reader._documentation[element] = comment.tokens
          .map((t) => t.lexeme)
          .join('\n');
    }
    super.visitTypeParameter(node);
  }

  @override
  void visitAnnotation(Annotation node) {
    if (!reader._isAnnotationValue(node.element)) return;
    final parent = node.parent;
    a.Element? element;
    if (parent is ClassDeclaration) element = parent.declaredFragment?.element;
    if (parent is ClassTypeAlias) element = parent.declaredFragment?.element;
    if (parent is FunctionDeclaration && parent.parent is CompilationUnit) {
      element = parent.declaredFragment?.element;
    }
    if (parent is MethodDeclaration) element = parent.declaredFragment?.element;
    if (parent is ConstructorDeclaration) {
      element = parent.declaredFragment?.element;
    }
    if (parent is FieldDeclaration && parent.fields.variables.length == 1) {
      element = parent.fields.variables.single.declaredFragment?.element;
    }
    final unit = node.thisOrAncestorOfType<CompilationUnit>()!;
    final fragment = unit.declaredFragment!;
    final location = fragment.lineInfo.getLocation(node.offset);
    Never reject(String code, String message) => throw BindingDiagnostic(
      code,
      message,
      SourceLocation(
        File(fragment.source.fullName).uri,
        node.offset,
        node.length,
        line: location.lineNumber,
        column: location.columnNumber,
      ),
    );
    if (element == null) {
      reject(
        'NAPI_PLACEMENT',
        'Place @NAPI() on a top-level function, class, or single class member.',
      );
    }
    final config = reader._config(element);
    final hasBigintOption =
        node.arguments?.arguments.any(
          (argument) =>
              argument is NamedArgument && argument.name.lexeme == 'bigint',
        ) ??
        false;
    if (hasBigintOption && config?.exclude == true) {
      reject('NAPI_SELECTION', 'bigint and exclude cannot be combined.');
    }
    if (hasBigintOption && element is! a.TopLevelFunctionElement) {
      reject(
        'NAPI_PLACEMENT',
        'bigint is only supported on a top-level function.',
      );
    }
    if (element.isPrivate) {
      reject('NAPI_VISIBILITY', 'An annotated declaration must be public.');
    }
    if (element.enclosingElement case final a.ClassElement owner) {
      if (reader._config(owner) == null) {
        reject(
          'NAPI_SELECTION',
          'A member annotation requires @NAPI() on its owning class.',
        );
      }
    } else if (element is! a.TopLevelFunctionElement &&
        element is! a.ClassElement) {
      reject('NAPI_PLACEMENT', 'Member annotations require an owning class.');
    } else if (config?.exclude == true) {
      reject('NAPI_PLACEMENT', 'exclude is only valid on a class member.');
    }
    super.visitAnnotation(node);
  }
}
