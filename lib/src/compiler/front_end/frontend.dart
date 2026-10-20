import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart' as a;
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart' as a;
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:path/path.dart' as p;

import '../../api/annotation.dart';
import '../analysis/validate.dart';
import '../ir/model.dart';
import '../ir/defaults.dart';
import 'external.dart';
import 'sdk_analysis.dart';

/// Source annotations and external bindings meet at this boundary.
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
  final bool native;
  const AnnotationFrontend({
    this.sdkPath,
    this.packagesPath,
    this.native = false,
  });

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
    final contexts = createSdkAnalysisContext(
      native: native,
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

/// Resolve external selections through the same semantic reader as annotations.
///
/// The target may be a file or package URI. Package URIs use [packagesPath], or
/// the current package's `.dart_tool/package_config.json` when omitted.
final class ExternalFrontend implements BindingFrontend {
  final ExternalLibrary selections;
  final String? sdkPath;
  final String? packagesPath;
  final bool native;
  const ExternalFrontend(
    this.selections, {
    this.sdkPath,
    this.packagesPath,
    this.native = false,
  });

  @override
  Future<BindingModule> read(Uri library) async {
    final packages = packagesPath == null
        ? File('.dart_tool/package_config.json').absolute.path
        : File(packagesPath!).absolute.path;
    if ((library.scheme != 'file' && library.scheme != 'package') ||
        (library.scheme == 'file' && !File.fromUri(library).existsSync()) ||
        (library.scheme == 'package' && !File(packages).existsSync())) {
      throw const BindingDiagnostic(
        'NAPI_INPUT',
        'Provide an existing file library or a package URI with package configuration.',
      );
    }
    final anchor = p.normalize(
      library.scheme == 'file' ? File.fromUri(library).absolute.path : packages,
    );
    final contexts = createSdkAnalysisContext(
      native: native,
      path: anchor,
      sdkPath: sdkPath,
      packageConfigFile: File(packages).existsSync() ? packages : null,
    );
    try {
      final session = contexts.contextFor(anchor).currentSession;
      final path = session.uriConverter.uriToPath(library);
      if (path == null || !File(path).existsSync()) {
        throw BindingDiagnostic(
          'NAPI_INPUT',
          'Cannot resolve library $library.',
        );
      }
      final result = await session.getResolvedLibrary(path);
      if (result is! ResolvedLibraryResult) {
        throw const BindingDiagnostic(
          'NAPI_INPUT',
          'Input must be a Dart library.',
        );
      }
      return await _Reader(
        File(path).absolute.uri,
        null,
      ).readExternal(result, selections);
    } finally {
      await contexts.dispose();
    }
  }
}

final class _Reader {
  final Uri entry;
  final a.ClassElement? annotationClass;
  final _externalConfigs = <a.Element, NAPI>{};
  final _aliasMemberConfigs = <a.TypeAliasElement, Map<a.Element, NAPI>>{};
  final _selectedClasses = <a.ClassElement>{};
  final _selectedConcreteTypes = <a.TypeAliasElement, a.InterfaceType>{};
  final _libraries = <a.LibraryElement, ResolvedLibraryResult>{};
  final _documentation = <a.Element, String>{};
  final _typeParameterIds = <a.TypeParameterElement, DeclarationId>{};
  final _opaqueParameters = <DeclarationId>{};
  final _defaultIdentities = <DartObject, Object>{};
  final _libraryImportUris = <a.LibraryElement, Set<Uri>>{};
  _Reader(this.entry, this.annotationClass);

  Future<BindingModule> readExternal(
    ResolvedLibraryResult root,
    ExternalLibrary selections,
  ) async {
    _indexLibraryImports(root.element);
    final selected = <(ExternalDeclaration, a.Element)>[];
    for (final selection in selections.declarations) {
      final name = selection.name;
      final exported = root.element.exportNamespace.definedNames2[name];
      final element = exported == null ? null : _exportDeclaration(exported);
      final fallback = selection.source ?? _source(root.element);
      if (name.startsWith('_')) {
        final private =
            root.element.getTopLevelFunction(name) ??
            root.element.getTopLevelVariable(name) ??
            root.element.getClass(name);
        throw BindingDiagnostic(
          'NAPI_VISIBILITY',
          'External selection $name must be public.',
          private == null ? fallback : _source(private),
        );
      }
      if (element == null) {
        throw BindingDiagnostic(
          'NAPI_SELECTION',
          'No public export named $name in ${root.element.uri}.',
          fallback,
        );
      }
      if (element is a.MultiplyDefinedElement) {
        final source = element.conflictingElements.isEmpty
            ? fallback
            : _source(element.conflictingElements.first);
        throw BindingDiagnostic(
          'NAPI_AMBIGUOUS',
          'External selection $name is ambiguous between '
              '${element.conflictingElements.map((e) => e.library!.uri).join(', ')}.',
          selection.source ?? source,
        );
      }
      if ((selection is ExternalFunction &&
              element is! a.TopLevelFunctionElement &&
              element is! a.TopLevelVariableElement) ||
          (selection is ExternalClass &&
              element is! a.ClassElement &&
              element is! a.TypeAliasElement)) {
        _reject(
          element,
          'NAPI_SELECTION',
          'External selection $name has the wrong declaration kind.',
        );
      }
      _setExternalConfig(element, selection.config, member: false);
      if (selection is ExternalClass && element is a.ClassElement) {
        _selectMembers(element, selection);
        _selectedClasses.add(element);
      } else if (selection is ExternalClass && element is a.TypeAliasElement) {
        final type = _concreteAliasType(element);
        _selectedConcreteTypes[element] = type;
        final owner = type.element as a.ClassElement;
        final configs = <a.Element, NAPI>{};
        _selectMembers(owner, selection, configs: configs);
        _aliasMemberConfigs[element] = configs;
        _selectedClasses.add(owner);
      }
      selected.add((selection, element));
    }
    await _load(root.element, result: root);
    selected.sort((x, y) => _compareDeclarations(x.$2, y.$2));
    final functions = <FunctionBinding>[];
    final classes = <ClassBinding>[];
    for (final (selection, element) in selected) {
      await _load(element.library!);
      if (element is a.TopLevelFunctionElement) {
        functions.add(_function(element, selection.name, selection.config));
      } else if (element is a.TopLevelVariableElement) {
        functions.add(
          _concreteFunction(element, selection.name, selection.config),
        );
      } else if (element is a.ClassElement) {
        classes.add(_class(element, selection.name, selection.config));
      } else if (element is a.TypeAliasElement) {
        final origin = _concreteAliasType(element).element.library;
        if (origin.uri.scheme != 'dart') await _load(origin);
        classes.add(_classAlias(element, selection.name, selection.config));
      }
    }
    final module = BindingModule(
      source: entry,
      importUri: root.element.uri,
      functions: functions,
      classes: classes,
    );
    validateDeclarations(module);
    return module;
  }

  void _setExternalConfig(
    a.Element element,
    NAPI config, {
    required bool member,
    Map<a.Element, NAPI>? configs,
  }) {
    final selections = configs ?? _externalConfigs;
    if (selections.containsKey(element)) {
      _reject(
        element,
        'NAPI_DUPLICATE',
        'Duplicate external selection ${element.name}.',
      );
    }
    if (config.exclude && !member) {
      _reject(
        element,
        'NAPI_PLACEMENT',
        'exclude is only valid on a class member.',
      );
    }
    if (config.exclude && config.name != null) {
      _reject(
        element,
        'NAPI_SELECTION',
        'name and exclude cannot be combined.',
      );
    }
    if (config.bigint &&
        (member ||
            (element is! a.TopLevelFunctionElement &&
                element is! a.TopLevelVariableElement))) {
      _reject(
        element,
        'NAPI_PLACEMENT',
        'bigint is only supported on a top-level function or concrete callable const.',
      );
    }
    _checkClassOptions(element, config);
    selections[element] = config;
  }

  void _checkClassOptions(a.Element element, NAPI config) {
    // The Dart declaration already names and orders all generic parameters.
    // Register the default payload mapping before reading members/parameters.
    final parameters = switch (element) {
      a.ClassElement() => element.typeParameters,
      a.TopLevelFunctionElement() => element.typeParameters,
      _ => const <a.TypeParameterElement>[],
    };
    if (!config.exclude) _opaqueParameters.addAll(parameters.map(_id));
    if (element is! a.ClassElement && element is! a.TypeAliasElement) {
      if (config.classPolicy != null ||
          config.cleanup != null ||
          config.valueConstructor != null ||
          config.valueFields != null) {
        _reject(
          element,
          'NAPI_PLACEMENT',
          'classPolicy, cleanup and value construction options are only valid on a class.',
        );
      }
      return;
    }
    if ((config.valueConstructor != null || config.valueFields != null) &&
        config.classPolicy != ClassPolicy.value) {
      _reject(
        element,
        'NAPI_SELECTION',
        'Value construction options require the value class policy.',
      );
    }
    if (config.valueFields != null && config.valueConstructor == null) {
      _reject(
        element,
        'NAPI_SELECTION',
        'valueFields requires valueConstructor.',
      );
    }
    if (config.classPolicy == ClassPolicy.resource) {
      if (config.cleanup == null) {
        _reject(
          element,
          'NAPI_SELECTION',
          'A resource policy requires a cleanup method name.',
        );
      }
    } else if (config.cleanup != null) {
      _reject(
        element,
        'NAPI_SELECTION',
        'cleanup requires the resource class policy.',
      );
    }
  }

  DeclarationId? _cleanup(a.ClassElement element, NAPI config) {
    _checkClassOptions(element, config);
    final name = config.cleanup;
    if (name == null) return null;
    final matches = _classMembers(element)
        .where((member) => member.name == name)
        .toList();
    if (matches.isEmpty) {
      _reject(
        element,
        'NAPI_SELECTION',
        'No declared cleanup method ${element.name}.$name.',
      );
    }
    if (matches.length != 1) {
      _reject(
        matches.first,
        'NAPI_AMBIGUOUS',
        'Cleanup selection ${element.name}.$name is ambiguous.',
      );
    }
    final member = matches.single;
    if (member.isPrivate) {
      _reject(member, 'NAPI_VISIBILITY', 'A cleanup method must be public.');
    }
    if (member is! a.MethodElement || member.isStatic) {
      _reject(
        member,
        'NAPI_SELECTION',
        'Cleanup must select a declared instance method.',
      );
    }
    return _id(member);
  }

  DeclarationId? _valueConstructor(a.ClassElement owner, NAPI config) {
    _checkClassOptions(owner, config);
    final name = config.valueConstructor;
    if (name == null) return null;
    final matches = owner.constructors
        .where((member) => member.name == name)
        .toList();
    if (matches.length != 1) {
      _reject(
        owner,
        'NAPI_SELECTION',
        'Select one declared value constructor ${owner.name}.$name.',
      );
    }
    final constructor = matches.single;
    if (constructor.isPrivate) {
      _reject(
        constructor,
        'NAPI_VISIBILITY',
        'A value constructor must be public.',
      );
    }
    return _id(constructor);
  }

  Map<String, DeclarationId> _valueFields(a.ClassElement owner, NAPI config) =>
      {
        for (final entry
            in (config.valueFields ?? const <String, String>{}).entries)
          entry.key: _valueField(owner, entry.value),
      };

  DeclarationId _valueField(a.ClassElement owner, String name) {
    final matches = _classMembers(owner)
        .where(
          (member) =>
              member.name == name &&
              (member is a.FieldElement || member is a.GetterElement),
        )
        .toList();
    if (matches.length != 1) {
      _reject(
        owner,
        'NAPI_SELECTION',
        'Select one own readable value member ${owner.name}.$name.',
      );
    }
    if (matches.single.isPrivate) {
      _reject(
        matches.single,
        'NAPI_VISIBILITY',
        'A value member must be public.',
      );
    }
    return _id(matches.single);
  }

  void _selectMembers(
    a.ClassElement owner,
    ExternalClass selection, {
    Map<a.Element, NAPI>? configs,
  }) {
    final members = _classMembers(owner);
    for (final member in selection.members) {
      final matches = members
          .where((e) => e.name == member.name && _memberKind(e) == member.kind)
          .toList();
      if (matches.isEmpty) {
        throw BindingDiagnostic(
          'NAPI_SELECTION',
          'No declared ${member.kind.name} ${owner.name}.${member.name}.',
          member.source ?? _source(owner),
        );
      }
      if (matches.length != 1) {
        _reject(
          matches.first,
          'NAPI_AMBIGUOUS',
          'External member selection ${owner.name}.${member.name} is ambiguous.',
        );
      }
      final element = matches.single;
      if (element.isPrivate) {
        _reject(
          element,
          'NAPI_VISIBILITY',
          'An external member selection must be public.',
        );
      }
      _setExternalConfig(
        element,
        member.config,
        member: true,
        configs: configs,
      );
    }
  }

  Future<BindingModule> read(ResolvedLibraryResult root) async {
    _indexLibraryImports(root.element);
    final candidates = root.element.exportNamespace.definedNames2.entries
        .where((e) => e.value is! a.MultiplyDefinedElement)
        .map((e) => MapEntry(e.key, _exportDeclaration(e.value)))
        .toList();
    // Source order is deterministic within an origin; reexports use origin URI.
    candidates.sort((x, y) => _compareDeclarations(x.value, y.value));
    final functions = <FunctionBinding>[];
    final classes = <ClassBinding>[];
    final seen = <a.Element>{};
    _selectedClasses.addAll(
      candidates
          .map((e) => e.value)
          .whereType<a.ClassElement>()
          .where((element) => _config(element) != null),
    );
    for (final candidate in candidates) {
      final element = candidate.value;
      if (element is a.TypeAliasElement && _config(element) != null) {
        final type = element.aliasedType;
        if (type is a.InterfaceType && type.element is a.ClassElement) {
          _selectedClasses.add(type.element as a.ClassElement);
          _selectedConcreteTypes[element] = type;
        }
      }
    }
    await _load(root.element, result: root);
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
      } else if (element is a.TopLevelVariableElement) {
        functions.add(_concreteFunction(element, candidate.key, config));
      } else if (element is a.ClassElement) {
        classes.add(_class(element, candidate.key, config));
      } else if (element is a.TypeAliasElement) {
        final origin = _concreteAliasType(element).element.library;
        if (origin.uri.scheme != 'dart') await _load(origin);
        classes.add(_classAlias(element, candidate.key, config));
      } else {
        _reject(
          element,
          'NAPI_PLACEMENT',
          '@NAPI() selects functions, concrete callable consts, classes and concrete class aliases.',
        );
      }
    }
    final module = BindingModule(
      source: entry,
      importUri: root.element.uri,
      functions: functions,
      classes: classes,
    );
    validateDeclarations(module);
    return module;
  }

  // Public namespaces expose a variable through its synthetic getter.
  a.Element _exportDeclaration(a.Element element) =>
      element is a.GetterElement &&
          element.isOriginVariable &&
          element.variable is a.TopLevelVariableElement
      ? element.variable
      : element;

  int _compareDeclarations(a.Element x, a.Element y) {
    final uri = x.library!.uri.toString().compareTo(y.library!.uri.toString());
    return uri != 0
        ? uri
        : x.firstFragment.offset.compareTo(y.firstFragment.offset);
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
            annotationClass == null &&
                    diagnostic.diagnosticCode.lowerCaseName ==
                        'ambiguous_export'
                ? 'NAPI_AMBIGUOUS'
                : 'NAPI_DART',
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
      annotationClass != null &&
      (_isAnnotation(element) ||
          (element is a.GetterElement &&
              element.variable.computeConstantValue()?.type?.element ==
                  annotationClass));

  NAPI? _config(a.Element element) {
    if (annotationClass == null) return _externalConfigs[element];
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
    final policyValue = value.getField('classPolicy');
    final policyIndex = policyValue?.getField('index')?.toIntValue();
    final classPolicy =
        policyIndex != null &&
            policyIndex >= 0 &&
            policyIndex < ClassPolicy.values.length
        ? ClassPolicy.values[policyIndex]
        : null;
    final cleanup = value.getField('cleanup')?.toStringValue();
    final valueConstructor = value
        .getField('valueConstructor')
        ?.toStringValue();
    final fieldsValue = value.getField('valueFields');
    final fieldsMap = fieldsValue?.toMapValue();
    final valueFields = fieldsMap == null ? null : <String, String>{};
    if ((valueConstructor == null &&
            value.getField('valueConstructor')?.isNull != true) ||
        (fieldsMap == null && fieldsValue?.isNull != true)) {
      _reject(
        element,
        'NAPI_ANNOTATION',
        'Value construction options must be resolved constants.',
      );
    }
    if (fieldsMap != null) {
      for (final entry in fieldsMap.entries) {
        final key = entry.key?.toStringValue();
        final field = entry.value?.toStringValue();
        if (key == null || field == null) {
          _reject(
            element,
            'NAPI_ANNOTATION',
            'valueFields must map Dart parameter names to member names.',
          );
        }
        valueFields![key] = field;
      }
    }
    if ((classPolicy == null && policyValue?.isNull != true) ||
        (cleanup == null && value.getField('cleanup')?.isNull != true)) {
      _reject(
        element,
        'NAPI_ANNOTATION',
        'Class policy configuration must have a known constant value.',
      );
    }
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
    return NAPI(
      name: name,
      exclude: exclude,
      bigint: bigint,
      classPolicy: classPolicy,
      cleanup: cleanup,
      valueConstructor: valueConstructor,
      valueFields: valueFields,
    );
  }

  FunctionBinding _function(
    a.TopLevelFunctionElement element,
    String path,
    NAPI config,
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

  FunctionBinding _concreteFunction(
    a.TopLevelVariableElement element,
    String path,
    NAPI config,
  ) {
    final node = _node(element);
    final initializer = node is VariableDeclaration ? node.initializer : null;
    if (!element.isConst ||
        initializer is! FunctionReference ||
        initializer.typeArguments == null) {
      _reject(
        element,
        'NAPI_CALLABLE',
        'Select a top-level const initialized directly with a function tear-off and explicit closed type arguments.',
      );
    }
    final target = switch (initializer.function) {
      SimpleIdentifier(:final element) => element,
      PrefixedIdentifier(:final identifier) => identifier.element,
      PropertyAccess(:final propertyName) => propertyName.element,
      _ => null,
    };
    if (target is! a.TopLevelFunctionElement &&
        !(target is a.MethodElement && target.isStatic)) {
      _reject(
        element,
        'NAPI_CALLABLE',
        'A concrete callable const must directly select a top-level function or static method.',
      );
    }
    final type = initializer.staticType;
    final arguments = initializer.typeArgumentTypes;
    if (type is! a.FunctionType ||
        type.typeParameters.isNotEmpty ||
        arguments == null ||
        arguments.isEmpty ||
        !arguments.every((argument) => isClosedConcreteType(_type(argument)))) {
      _reject(
        element,
        'NAPI_GENERIC',
        'A concrete callable const requires explicit closed type arguments without dynamic or open generic types.',
      );
    }
    // The initializer retains the target's defaults. An explicit function type
    // can erase them or widen its signature; only the same signature is safe.
    if (element.type != type) {
      _reject(
        element,
        'NAPI_CALLABLE',
        'A concrete callable const must retain its initializer function type; remove or match the declared type.',
      );
    }
    final executable = target as a.ExecutableElement;
    return FunctionBinding(
      declaration: _id(element),
      exportName: config.name ?? path,
      source: _source(element),
      exportSurface: entry,
      callPath: path,
      parameters: type.formalParameters.indexed.map(
        (p) => _parameter(p.$2, owner: _id(element), path: 'parameter:${p.$1}'),
      ),
      result: _type(type.returnType, owner: _id(element), path: 'return'),
      typeParameters: const [],
      documentation: element.documentationComment ?? _documentation[element],
      isExternal: executable.isExternal,
      isAsync: executable.firstFragment.isAsynchronous,
      isGenerator: executable.firstFragment.isGenerator,
      bigint: config.bigint,
    );
  }

  a.InterfaceType _concreteAliasType(a.TypeAliasElement alias) {
    final type = alias.aliasedType;
    if (alias.typeParameters.isNotEmpty ||
        type is! a.InterfaceType ||
        type.element is! a.ClassElement ||
        type.nullabilitySuffix != NullabilitySuffix.none) {
      _reject(
        alias,
        'NAPI_GENERIC',
        'Select a non-generic, non-null alias of a concrete class type.',
      );
    }
    if (_type(type).semantics != ValueSemantics.reference) {
      _reject(
        alias,
        'NAPI_PLACEMENT',
        'A concrete class alias must select a reference class, not a scalar or container type.',
      );
    }
    return type;
  }

  ClassBinding _classAlias(a.TypeAliasElement alias, String path, NAPI config) {
    final type = _concreteAliasType(alias);
    final types = type.element.library.typeSystem;
    if (config.classPolicy != ClassPolicy.value &&
        _selectedConcreteTypes.entries.any(
          (entry) =>
              _config(entry.key)?.classPolicy != ClassPolicy.value &&
              entry.value.element == type.element &&
              entry.value != type &&
              types.isSubtypeOf(type, entry.value) &&
              types.isSubtypeOf(entry.value, type),
        )) {
      _reject(
        alias,
        'NAPI_GENERIC',
        'Selected concrete aliases must be distinguishable by Dart type tests.',
      );
    }
    return _class(
      type.element as a.ClassElement,
      path,
      config,
      alias: alias,
      instantiatedType: type,
      memberConfigs: _aliasMemberConfigs[alias],
    );
  }

  ClassBinding _class(
    a.ClassElement element,
    String path,
    NAPI config, {
    a.TypeAliasElement? alias,
    a.InterfaceType? instantiatedType,
    Map<a.Element, NAPI>? memberConfigs,
  }) {
    final type = instantiatedType ?? element.thisType;
    final selected = alias ?? element;
    final members = instantiatedType == null
        ? _classMembers(element)
        : _instantiatedMembers(instantiatedType);
    return ClassBinding(
      declaration: _id(element),
      selectionDeclaration: alias == null ? null : _id(alias),
      instantiatedType: instantiatedType == null
          ? null
          : _type(instantiatedType, owner: _id(alias!), path: 'instantiation')
                as DeclaredType,
      concreteSupertypes: instantiatedType == null
          ? const []
          : _selectedConcreteTypes.values
                .where(
                  (other) =>
                      other.element == element &&
                      element.library.typeSystem.isSubtypeOf(
                        instantiatedType,
                        other,
                      ) &&
                      !element.library.typeSystem.isSubtypeOf(
                        other,
                        instantiatedType,
                      ),
                )
                .map((other) => _type(other) as DeclaredType),
      exportName: config.name ?? path,
      source: _source(selected),
      classPolicy: config.classPolicy ?? ClassPolicy.reference,
      cleanup: _cleanup(element, config),
      valueConstructor: _valueConstructor(element, config),
      valueFields: _valueFields(element, config),
      exportSurface: entry,
      callPath: path,
      documentation: selected.documentationComment ?? _documentation[selected],
      typeParameters: alias == null
          ? element.typeParameters.map(_typeParameter)
          : const [],
      members: members
          .where((e) => e.isPublic)
          .map((member) => _member(member, configs: memberConfigs)),
      inheritedInstanceMembers: config.classPolicy != ClassPolicy.value
          ? _inheritedInstanceMembers(
              element,
              instantiatedType: instantiatedType,
            )
          : const [],
      isAbstract: element.isAbstract,
      isSealed: element.isSealed,
      isBase: element.isBase,
      isInterface: element.isInterface,
      isFinal: element.isFinal,
      isMixinClass: element.isMixinClass,
      supertype: type.superclass == null
          ? null
          : _type(type.superclass!, owner: _id(element), path: 'supertype'),
      interfaces: type.interfaces.indexed.map(
        (t) => _type(t.$2, owner: _id(element), path: 'interface:${t.$1}'),
      ),
      mixins: type.mixins.indexed.map(
        (t) => _type(t.$2, owner: _id(element), path: 'mixin:${t.$1}'),
      ),
      allSupertypes: type.allSupertypes.map(
        (type) => _type(type) as DeclaredType,
      ),
      superclassChain: _superclassChain(type),
    );
  }

  Iterable<DeclaredType> _superclassChain(a.InterfaceType type) sync* {
    var parent = type.superclass;
    while (parent != null) {
      yield _type(parent) as DeclaredType;
      parent = parent.superclass;
    }
  }

  Iterable<InheritedInstanceMember> _inheritedInstanceMembers(
    a.ClassElement element, {
    a.InterfaceType? instantiatedType,
  }) sync* {
    final ownerType = instantiatedType ?? element.thisType;
    final actualMembers = <(MemberKind, String), a.ExecutableElement?>{};
    for (final type in ownerType.allSupertypes) {
      final ancestor = type.element;
      if (!_selectedClasses.contains(ancestor) ||
          _config(ancestor)?.classPolicy == ClassPolicy.value) {
        continue;
      }
      for (final contract in [
        ...type.methods,
        ...type.getters,
        ...type.setters,
      ]) {
        if (!contract.isPublic ||
            contract.isStatic ||
            _config(_memberDeclaration(contract))?.exclude == true) {
          continue;
        }
        final kind = _memberKind(contract);
        final name = contract.name!;
        final actual = actualMembers.putIfAbsent(
          (kind, name),
          () => switch (kind) {
            MemberKind.method => ownerType.lookUpMethod(
              name,
              element.library,
              concrete: true,
            ),
            MemberKind.getter => ownerType.lookUpGetter(
              name,
              element.library,
              concrete: true,
            ),
            MemberKind.setter => ownerType.lookUpSetter(
              name,
              element.library,
              concrete: true,
            ),
            _ => null,
          },
        );
        if (actual == null ||
            actual.enclosingElement == element ||
            actual.baseElement == contract.baseElement) {
          continue;
        }
        yield InheritedInstanceMember(
          member: _member(actual),
          contract: _id(_memberDeclaration(contract)),
          contractType: _type(type) as DeclaredType,
          isCompatible: element.library.typeSystem.isSubtypeOf(
            actual.type,
            contract.type,
          ),
        );
      }
    }
  }

  List<a.Element> _classMembers(a.ClassElement element) => <a.Element>[
    ...element.constructors,
    ...element.fields.where((e) => !e.isOriginGetterSetter),
    ...element.methods,
    ...element.getters.where((e) => !e.isOriginVariable),
    ...element.setters.where((e) => !e.isOriginVariable),
  ]..sort((x, y) => x.firstFragment.offset.compareTo(y.firstFragment.offset));

  List<a.Element> _instantiatedMembers(a.InterfaceType type) => <a.Element>[
    ...type.constructors,
    ...type.getters
        .where((getter) => getter.isOriginVariable)
        .map((getter) => getter.variable),
    ...type.methods,
    ...type.getters.where((getter) => !getter.isOriginVariable),
    ...type.setters.where((setter) => !setter.isOriginVariable),
  ]..sort((x, y) => x.firstFragment.offset.compareTo(y.firstFragment.offset));

  MemberKind _memberKind(a.Element element) => switch (element) {
    a.ConstructorElement() => MemberKind.constructor,
    a.MethodElement() => MemberKind.method,
    a.GetterElement() => MemberKind.getter,
    a.SetterElement() => MemberKind.setter,
    _ => MemberKind.field,
  };

  a.Element _memberDeclaration(a.Element element) =>
      element is a.PropertyAccessorElement && element.isOriginVariable
      ? element.variable.baseElement
      : element.baseElement;

  MemberBinding _member(a.Element element, {Map<a.Element, NAPI>? configs}) {
    final declaration = _memberDeclaration(element);
    final config = configs == null
        ? _config(declaration)
        : configs[declaration];
    final kind = _memberKind(element);
    final executable = element is a.ExecutableElement ? element : null;
    if (kind == MemberKind.method && config?.exclude != true) {
      _opaqueParameters.addAll(executable!.typeParameters.map(_id));
    }
    final field = element is a.FieldElement ? element : null;
    final constructor = element is a.ConstructorElement ? element : null;
    final node = _node(element);
    return MemberBinding(
      declaration: _id(element),
      source: _source(declaration),
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
  }) {
    final type = _type(element.type, owner: owner, path: path);
    final opaque =
        type is TypeParameterType &&
        _opaqueParameters.contains(type.declaration);
    final defaultValue = element.hasDefaultValue
        ? element.computeConstantValue()
        : null;
    final defaultType = defaultValue?.type;
    return ParameterBinding(
      element.name ?? '',
      type,
      presence: opaque
          ? (element.isOptionalPositional || element.isOptionalNamed
                ? ParameterPresence.opaqueOptional
                : ParameterPresence.opaqueRequired)
          : null,
      kind: element.isRequiredNamed
          ? ParameterKind.requiredNamed
          : element.isOptionalNamed
          ? ParameterKind.optionalNamed
          : element.isOptionalPositional
          ? ParameterKind.optionalPositional
          : ParameterKind.requiredPositional,
      defaultSource: element.defaultValueCode,
      defaultValue: element.hasDefaultValue
          ? _parameterDefault(element, defaultValue)
          : null,
      defaultIdentity: defaultValue == null || !defaultValue.hasKnownValue
          ? null
          : _defaultIdentities.putIfAbsent(defaultValue, Object.new),
      defaultTypeIsAssignable:
          defaultType != null &&
          (element.library?.typeSystem.isSubtypeOf(defaultType, element.type) ??
              false),
      hasDefault: element.hasDefaultValue,
      source: element.firstFragment.libraryFragment == null
          ? null
          : _source(element),
      documentation: element.documentationComment ?? _documentation[element],
      isInitializingFormal: element is a.FieldFormalParameterElement,
      isSuperFormal: element is a.SuperFormalParameterElement,
      isCovariant: element.isCovariant,
    );
  }

  ConstantDefault? _parameterDefault(
    a.FormalParameterElement element,
    DartObject? value,
  ) {
    try {
      return _constantDefault(value, ConstantDefaultBudget());
    } on ConstantDefaultLimit catch (error) {
      throw BindingDiagnostic(
        'NAPI_DEFAULT',
        error.toString(),
        _source(element),
      );
    }
  }

  ConstantDefault? _constantDefault(
    DartObject? value,
    ConstantDefaultBudget budget, [
    int depth = 0,
  ]) {
    if (value == null || !value.hasKnownValue) return null;
    if (value.isNull) {
      budget.visit(depth, leaf: true);
      return const ScalarDefault(null);
    }
    final scalar =
        value.toBoolValue() ??
        value.toIntValue() ??
        value.toDoubleValue() ??
        value.toStringValue();
    budget.visit(depth, leaf: scalar != null);
    if (scalar != null) {
      if (depth > 0 && scalar is String) budget.text(scalar.length);
      return ScalarDefault(scalar);
    }
    final actual = value.type;
    if (actual == null) return null;
    _checkConstantType(actual, budget);
    final type = _type(actual);
    final invocation = value.constructorInvocation;
    if (invocation != null && actual is a.InterfaceType) {
      final constructor = invocation.constructor;
      final constructorType = _type(constructor.returnType);
      if (constructor.enclosingElement is! a.ClassElement ||
          constructor.isPrivate ||
          constructor.enclosingElement.isPrivate ||
          constructorType is! DeclaredType ||
          type is! DeclaredType ||
          constantTypeSource(
                constructorType,
                declarationSource: constantDeclarationKey,
              ) ==
              null) {
        return _namedObjectDefault(value, actual, budget);
      }
      final positional = <ConstantDefault>[];
      final named = <String, ConstantDefault>{};
      for (final argument in invocation.positionalArguments) {
        final child = _constantDefault(argument, budget, depth + 1);
        if (child == null) return _namedObjectDefault(value, actual, budget);
        positional.add(child);
      }
      for (final entry in invocation.namedArguments.entries) {
        if (entry.key.startsWith('_')) {
          return _namedObjectDefault(value, actual, budget);
        }
        final child = _constantDefault(entry.value, budget, depth + 1);
        if (child == null) return _namedObjectDefault(value, actual, budget);
        named[entry.key] = child;
      }
      return ObjectDefault(
        type,
        constructorType,
        _id(constructor),
        positional,
        named,
        supertypes: actual.allSupertypes.map(
          (type) => _type(type) as DeclaredType,
        ),
      );
    }
    if (constantTypeSource(type, declarationSource: constantDeclarationKey) ==
        null) {
      return null;
    }
    if (actual.isDartCoreList) {
      final values = value.toListValue();
      if (values == null) return null;
      final elements = <ConstantDefault>[];
      for (final value in values) {
        final child = _constantDefault(value, budget, depth + 1);
        if (child == null) return null;
        elements.add(child);
      }
      return ListDefault(type, elements);
    }
    if (actual.isDartCoreMap) {
      final values = value.toMapValue();
      if (values == null) return null;
      final entries = <(ConstantDefault, ConstantDefault)>[];
      for (final entry in values.entries) {
        final key = _constantDefault(entry.key, budget, depth + 1);
        final value = _constantDefault(entry.value, budget, depth + 1);
        if (key == null || value == null) return null;
        entries.add((key, value));
      }
      return MapDefault(type, entries);
    }
    final record = value.toRecordValue();
    if (record == null) return null;
    final positional = <ConstantDefault>[];
    final named = <String, ConstantDefault>{};
    for (final value in record.positional) {
      final child = _constantDefault(value, budget, depth + 1);
      if (child == null) return null;
      positional.add(child);
    }
    for (final entry in record.named.entries) {
      final child = _constantDefault(entry.value, budget, depth + 1);
      if (child == null) return null;
      named[entry.key] = child;
    }
    return RecordDefault(type, positional, named);
  }

  NamedObjectDefault? _namedObjectDefault(
    DartObject value,
    a.InterfaceType type,
    ConstantDefaultBudget budget,
  ) {
    if (type.element is! a.ClassElement) return null;
    var variable = value.variable;
    final visited = <a.VariableElement>{};
    while (variable != null && variable.isConst && visited.add(variable)) {
      budget.visit(0, leaf: true);
      final owner = variable.enclosingElement;
      final public =
          variable.isPublic &&
          (variable is a.TopLevelVariableElement ||
              variable is a.FieldElement &&
                  variable.isStatic &&
                  owner is a.InterfaceElement &&
                  owner.isPublic);
      if (public && variable.computeConstantValue() == value) {
        return NamedObjectDefault(
          _type(type) as DeclaredType,
          _id(variable),
          type.allSupertypes.map((type) => _type(type) as DeclaredType),
        );
      }
      var initializer = variable.constantInitializer;
      while (initializer is ParenthesizedExpression) {
        initializer = initializer.expression;
      }
      final target = switch (initializer) {
        SimpleIdentifier(:final element) => element,
        PrefixedIdentifier(:final identifier) => identifier.element,
        PropertyAccess(:final propertyName) => propertyName.element,
        _ => null,
      };
      variable = target is a.GetterElement
          ? target.variable
          : target is a.VariableElement
          ? target
          : null;
    }
    return null;
  }

  void _checkConstantType(
    a.DartType type,
    ConstantDefaultBudget budget, [
    int depth = 0,
  ]) {
    budget.visit(
      depth,
      leaf:
          type is! a.RecordType &&
          (type is! a.InterfaceType || type.typeArguments.isEmpty),
    );
    final children = [
      ...?type.alias?.typeArguments,
      if (type is a.InterfaceType) ...type.typeArguments,
      if (type is a.RecordType) ...[
        for (final field in type.positionalFields) field.type,
        for (final field in type.namedFields) field.type,
      ],
    ];
    for (final child in children) {
      _checkConstantType(child, budget, depth + 1);
    }
  }

  TypeParameterBinding _typeParameter(a.TypeParameterElement element) =>
      TypeParameterBinding(
        declaration: _id(element),
        opaque: _opaqueParameters.contains(_id(element)),
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
            nullable:
                type.alias!.element.aliasedType.nullabilitySuffix ==
                NullabilitySuffix.question,
            documentation: type.alias!.element.documentationComment,
            source: _source(type.alias!.element),
            typeArguments: type.alias!.typeArguments.indexed.map(
              (t) => _type(t.$2, owner: owner, path: '$path.alias:${t.$1}'),
            ),
          );
    if (type.isDartCoreInt) {
      return SafeIntType(nullability: nullable, alias: alias);
    }
    if (type is a.InterfaceType) {
      final semantics =
          type.isDartCoreList ||
              type.isDartCoreMap ||
              type.isDartCoreSet ||
              _id(type.element) == dictionaryDeclaration
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

  // Analyzer canonicalizes package files even when Dart loads them through a
  // relative file import. Keep the URI graph used by the compiler instead.
  void _indexLibraryImports(a.LibraryElement root) {
    final pending = [(root, root.uri)];
    while (pending.isNotEmpty) {
      final (library, uri) = pending.removeLast();
      if (library.uri.scheme == 'dart') continue;
      final uris = _libraryImportUris.putIfAbsent(library, () => <Uri>{});
      if (!uris.add(uri)) continue;
      final fragments = [(library.firstFragment, uri)];
      final seen = <(a.LibraryFragment, Uri)>{};
      while (fragments.isNotEmpty) {
        final (fragment, uri) = fragments.removeLast();
        if (!seen.add((fragment, uri))) continue;
        for (final directive in [
          ...fragment.libraryImports,
          ...fragment.libraryExports,
        ]) {
          if (directive.uri case a.DirectiveUriWithLibrary(
            :final library,
            :final relativeUri,
          )) {
            pending.add((library, uri.resolveUri(relativeUri)));
          }
        }
        for (final part in fragment.partIncludes) {
          if (part.uri case a.DirectiveUriWithUnit(
            :final libraryFragment,
            :final relativeUri,
          )) {
            fragments.add((libraryFragment, uri.resolveUri(relativeUri)));
          }
        }
      }
    }
  }

  Uri _libraryImportUri(a.LibraryElement library) {
    final uris = _libraryImportUris[library];
    if (uris == null) return library.uri;
    if (uris.length != 1) {
      throw BindingDiagnostic(
        'NAPI_INPUT',
        'Library ${library.uri} is loaded through distinct import URIs: '
            '${uris.join(', ')}. Use consistent import URIs for this library.',
        _source(library),
      );
    }
    return uris.single;
  }

  DeclarationId _id(a.Element element) {
    if (element is a.TypeParameterElement &&
        _typeParameterIds.containsKey(element)) {
      return _typeParameterIds[element]!;
    }
    final owner = element.enclosingElement;
    return DeclarationId(
      element.library == null ? entry : _libraryImportUri(element.library!),
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
        a.TopLevelVariableElement() => DeclarationKind.variable,
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
    if (parent is GenericTypeAlias) element = parent.declaredFragment?.element;
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
    if (parent is TopLevelVariableDeclaration &&
        parent.variables.variables.length == 1) {
      element = parent.variables.variables.single.declaredFragment?.element;
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
        'Place @NAPI() on a top-level function, single concrete callable const, class, concrete class alias, or single class member.',
      );
    }
    final config = reader._config(element);
    final hasClassOption =
        node.arguments?.arguments.any(
          (argument) =>
              argument is NamedArgument &&
              const {
                'classPolicy',
                'cleanup',
                'valueConstructor',
                'valueFields',
              }.contains(argument.name.lexeme),
        ) ??
        false;
    if (hasClassOption &&
        element is! a.ClassElement &&
        element is! a.TypeAliasElement) {
      reject(
        'NAPI_PLACEMENT',
        'classPolicy, cleanup and value construction options are only valid on a class.',
      );
    }
    if (config != null) reader._checkClassOptions(element, config);
    final hasBigintOption =
        node.arguments?.arguments.any(
          (argument) =>
              argument is NamedArgument && argument.name.lexeme == 'bigint',
        ) ??
        false;
    if (hasBigintOption && config?.exclude == true) {
      reject('NAPI_SELECTION', 'bigint and exclude cannot be combined.');
    }
    if (hasBigintOption &&
        element is! a.TopLevelFunctionElement &&
        element is! a.TopLevelVariableElement) {
      reject(
        'NAPI_PLACEMENT',
        'bigint is only supported on a top-level function or concrete callable const.',
      );
    }
    if (element.isPrivate) {
      reject('NAPI_VISIBILITY', 'An annotated declaration must be public.');
    }
    if (element.enclosingElement case final a.ClassElement owner) {
      if (reader._config(owner) == null &&
          !reader._selectedClasses.contains(owner)) {
        reject(
          'NAPI_SELECTION',
          'A member annotation requires @NAPI() on its owning class.',
        );
      }
    } else if (element is! a.TopLevelFunctionElement &&
        element is! a.TopLevelVariableElement &&
        element is! a.ClassElement &&
        element is! a.TypeAliasElement) {
      reject('NAPI_PLACEMENT', 'Member annotations require an owning class.');
    } else if (config?.exclude == true) {
      reject('NAPI_PLACEMENT', 'exclude is only valid on a class member.');
    }
    super.visitAnnotation(node);
  }
}
