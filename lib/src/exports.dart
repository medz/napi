import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/error.dart';
// The public factory omits declaredVariables; use the same SDK lookup as it.
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
// ignore: implementation_imports
import 'package:analyzer/src/util/sdk.dart';
import 'package:path/path.dart' as path;

import 'sdk.dart';

enum ValueKind {
  voidType,
  boolType,
  intType,
  doubleType,
  stringType,
  uint8ListType,
  listType,
  mapType,
  recordType,
}

typedef RecordField = ({String name, ValueType type});
typedef RecordAlias = ({
  String name,
  String libraryUri,
  bool nullable,
  String? documentationComment,
});

final class ValueType {
  const ValueType(
    this.kind, {
    this.nullable = false,
    this.elementType,
    this.recordFields = const <RecordField>[],
    this.recordAlias,
  });

  final ValueKind kind;
  final bool nullable;
  final ValueType? elementType;
  final List<RecordField> recordFields;
  final RecordAlias? recordAlias;
}

final class Parameter {
  const Parameter({required this.name, required this.type});

  final String name;
  final ValueType type;
}

final class Export {
  const Export({
    required this.name,
    required this.parameters,
    required this.returnType,
    this.isAsync = false,
    this.documentationComment,
  });

  final String name;
  final List<Parameter> parameters;

  /// The completion value type when [isAsync] is true.
  final ValueType returnType;
  final bool isAsync;
  final String? documentationComment;
}

final class ExportError implements Exception {
  const ExportError(this.path, this.line, this.column, this.message);

  final String path;
  final int line;
  final int column;
  final String message;

  @override
  String toString() => '$path:$line:$column: $message';
}

/// Binding names that are reserved in JavaScript ES modules.
const javascriptKeywords = {
  'arguments',
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
  'eval',
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

// Type keywords and global constructors used by the generated declarations.
const _reservedTypeNames = {
  'any',
  'unknown',
  'never',
  'number',
  'bigint',
  'boolean',
  'string',
  'symbol',
  'void',
  'object',
  'undefined',
  'readonly',
  'keyof',
  'infer',
  'unique',
  'Promise',
  'Array',
  'Record',
  'Uint8Array',
};

const _objectMemberNames = {
  'toString',
  'hashCode',
  'runtimeType',
  'noSuchMethod',
};

// Fixed strong and weak export names in the Dart 3.13.5 Wasm runtime.
const _dartWasmExportNames = {
  r'$invokeMain',
  r'$invokeCallback',
  r'$wasmI8ArrayGet',
  r'$wasmI8ArraySet',
  r'$wasmI16ArrayGet',
  r'$wasmI16ArraySet',
  r'$wasmI32ArrayGet',
  r'$wasmI32ArraySet',
  r'$wasmF32ArrayGet',
  r'$wasmF32ArraySet',
  r'$wasmF64ArrayGet',
  r'$wasmF64ArraySet',
};

/// Resolves a Dart library and reads its annotated function signatures.
///
/// Parts belong to the same library and are included. Imports and re-exports
/// are not scanned for additional exports.
Future<List<Export>> readExports(String sourcePath) async {
  final absolutePath = path.normalize(path.absolute(sourcePath));
  if (!File(absolutePath).existsSync()) {
    throw ExportError(absolutePath, 1, 1, 'Dart source file does not exist.');
  }

  final sdkPath = getSdkPath();
  // The public analyzer factory cannot set the compiler's environment.
  final contexts = AnalysisContextCollectionImpl(
    includedPaths: [absolutePath],
    sdkPath: sdkPath,
    declaredVariables: wasmLibraryVariables(sdkPath),
  );
  try {
    final session = contexts.contextFor(absolutePath).currentSession;
    final result = await session.getResolvedLibrary(absolutePath);
    if (result is! ResolvedLibraryResult) {
      throw ExportError(
        absolutePath,
        1,
        1,
        'The entry point must be a Dart library, not a part file.',
      );
    }

    final exports = <Export>[];
    final names = <String>{};
    final recordAliases = <String, RecordAlias>{};
    for (final unit in result.units) {
      final errors =
          unit.diagnostics
              .where(
                (error) =>
                    error.diagnosticCode.severity == DiagnosticSeverity.ERROR,
              )
              .toList()
            ..sort((a, b) => a.offset.compareTo(b.offset));
      if (errors.isNotEmpty) {
        _fail(unit, errors.first.offset, errors.first.message);
      }
      unit.unit.accept(_ExportVisitor(unit, exports, names, recordAliases));
    }
    if (exports.isEmpty) {
      throw ExportError(absolutePath, 1, 1, 'No @napi functions found.');
    }
    return List.unmodifiable(exports);
  } finally {
    await contexts.dispose();
  }
}

Never _fail(FileResult unit, int offset, String message) {
  final location = unit.lineInfo.getLocation(offset);
  throw ExportError(
    unit.path,
    location.lineNumber,
    location.columnNumber,
    message,
  );
}

class _ExportVisitor extends RecursiveAstVisitor<void> {
  _ExportVisitor(this.unit, this.exports, this.names, this.recordAliases);

  final ResolvedUnitResult unit;
  final List<Export> exports;
  final Set<String> names;
  final Map<String, RecordAlias> recordAliases;

  @override
  void visitAnnotation(Annotation node) {
    final annotationType = node.elementAnnotation?.computeConstantValue()?.type;
    if (annotationType is! InterfaceType ||
        annotationType.element.name != 'Napi' ||
        annotationType.element.library.uri.toString() !=
            'package:napi/napi.dart') {
      return;
    }

    final declaration = node.parent;
    if (declaration is! FunctionDeclaration ||
        declaration.declaredFragment?.element is! TopLevelFunctionElement ||
        declaration.isGetter ||
        declaration.isSetter) {
      _fail(
        unit,
        node.offset,
        '@napi supports public top-level functions only.',
      );
    }

    final name = declaration.name.lexeme;
    if (name.startsWith('_')) {
      _fail(unit, declaration.name.offset, '@napi functions must be public.');
    }
    if (javascriptKeywords.contains(name)) {
      _fail(
        unit,
        declaration.name.offset,
        '"$name" is a reserved JavaScript export name.',
      );
    }
    if (_dartWasmExportNames.contains(name)) {
      _fail(
        unit,
        declaration.name.offset,
        '"$name" is a reserved Dart Wasm export name.',
      );
    }
    if (name == 'then') {
      _fail(
        unit,
        declaration.name.offset,
        '"then" cannot be exported because JavaScript dynamic import treats it as a Promise callback.',
      );
    }
    if (!names.add(name)) {
      _fail(unit, node.offset, 'Duplicate @napi annotation on "$name".');
    }

    final expression = declaration.functionExpression;
    if (declaration.externalKeyword != null) {
      _fail(
        unit,
        declaration.externalKeyword!.offset,
        '@napi functions must have a Dart implementation.',
      );
    }
    if (expression.typeParameters != null) {
      _fail(
        unit,
        expression.typeParameters!.offset,
        'Generic @napi functions are not supported.',
      );
    }
    if (expression.body.isGenerator) {
      _fail(
        unit,
        expression.body.offset,
        '@napi functions cannot be generators.',
      );
    }

    final element =
        declaration.declaredFragment!.element as TopLevelFunctionElement;
    final parameterNodes = expression.parameters!.parameters;
    final parameters = <Parameter>[];
    for (var i = 0; i < element.formalParameters.length; i++) {
      final parameter = element.formalParameters[i];
      final parameterNode = parameterNodes[i];
      if (!parameter.isRequiredPositional) {
        _fail(
          unit,
          parameterNode.offset,
          '@napi parameters must be required positional parameters.',
        );
      }
      parameters.add(
        Parameter(
          name: parameter.name!,
          type: _valueType(
            parameter.type,
            parameterNode.offset,
            annotation: parameterNode.type,
          ),
        ),
      );
    }

    final declaredReturnType = element.returnType;
    final returnOffset =
        declaration.returnType?.offset ?? declaration.name.offset;
    final isAsync =
        declaredReturnType is InterfaceType &&
        declaredReturnType.element.name == 'Future' &&
        declaredReturnType.element.library.uri.toString() == 'dart:async';
    var returnType = declaredReturnType;
    var returnAnnotation = declaration.returnType;
    if (isAsync) {
      if (declaredReturnType.alias != null) {
        _fail(
          unit,
          returnOffset,
          'Type aliases are not supported in @napi signatures.',
        );
      }
      if (declaredReturnType.nullabilitySuffix == NullabilitySuffix.question) {
        _fail(unit, returnOffset, 'Nullable Future returns are not supported.');
      }
      returnType = declaredReturnType.typeArguments.single;
      returnAnnotation = returnAnnotation is NamedType
          ? returnAnnotation.typeArguments?.arguments.single
          : null;
    } else if (expression.body.isAsynchronous) {
      _fail(unit, returnOffset, 'Async @napi functions must return Future<T>.');
    }

    exports.add(
      Export(
        name: name,
        parameters: List.unmodifiable(parameters),
        returnType: _valueType(
          returnType,
          returnOffset,
          allowVoid: true,
          annotation: returnAnnotation,
        ),
        isAsync: isAsync,
        documentationComment: element.documentationComment,
      ),
    );
  }

  ValueType _valueType(
    DartType type,
    int offset, {
    bool allowVoid = false,
    TypeAnnotation? annotation,
  }) {
    if (type is RecordType) {
      return _recordType(type, offset, annotation);
    }
    if (type.alias != null && !_supportsLeafAliases(type)) {
      _fail(
        unit,
        offset,
        'Type aliases are not supported in @napi signatures.',
      );
    }

    final ValueKind kind;
    if (type is VoidType && allowVoid) {
      kind = ValueKind.voidType;
    } else if (type.isDartCoreBool) {
      kind = ValueKind.boolType;
    } else if (type.isDartCoreInt) {
      kind = ValueKind.intType;
    } else if (type.isDartCoreDouble) {
      kind = ValueKind.doubleType;
    } else if (type.isDartCoreString) {
      kind = ValueKind.stringType;
    } else if (type is InterfaceType &&
        type.element.library.uri.toString() == 'dart:core' &&
        (type.element.name == 'List' || type.element.name == 'Map')) {
      final isMap = type.element.name == 'Map';
      if (isMap) {
        final key = type.typeArguments.first;
        if (key.alias != null && !_supportsLeafAliases(key)) {
          _fail(
            unit,
            offset,
            'Type aliases are not supported in @napi signatures.',
          );
        }
        if (!key.isDartCoreString ||
            key.nullabilitySuffix == NullabilitySuffix.question) {
          _fail(
            unit,
            offset,
            'Map keys must be non-nullable String. Use Map<String, int> or Map<String, String>.',
          );
        }
      }
      final leaf = type.typeArguments.last;
      if (leaf is RecordType) {
        final elementAnnotation = annotation is NamedType
            ? annotation.typeArguments?.arguments.last
            : null;
        return ValueType(
          isMap ? ValueKind.mapType : ValueKind.listType,
          nullable: type.nullabilitySuffix == NullabilitySuffix.question,
          elementType: _recordType(
            leaf,
            elementAnnotation?.offset ?? offset,
            elementAnnotation,
          ),
        );
      }
      if (leaf.alias != null && !_supportsLeafAliases(leaf)) {
        _fail(
          unit,
          offset,
          'Type aliases are not supported in @napi signatures.',
        );
      }
      if (!leaf.isDartCoreBool &&
          !leaf.isDartCoreInt &&
          !leaf.isDartCoreDouble &&
          !leaf.isDartCoreString) {
        _fail(
          unit,
          offset,
          'Unsupported @napi collection leaf type "${leaf.getDisplayString()}". '
          'Use bool, int, double, or String (optionally nullable), as in List<int> or Map<String, String>.',
        );
      }
      return ValueType(
        isMap ? ValueKind.mapType : ValueKind.listType,
        nullable: type.nullabilitySuffix == NullabilitySuffix.question,
        elementType: _valueType(leaf, offset),
      );
    } else if (type is InterfaceType &&
        type.element.name == 'Uint8List' &&
        type.element.library.uri.toString() == 'dart:typed_data') {
      kind = ValueKind.uint8ListType;
    } else {
      _fail(
        unit,
        offset,
        'Unsupported @napi type "${type.getDisplayString()}".',
      );
    }

    return ValueType(
      kind,
      nullable: type.nullabilitySuffix == NullabilitySuffix.question,
    );
  }

  ValueType _recordType(
    RecordType type,
    int offset,
    TypeAnnotation? annotation,
  ) {
    if (type.positionalFields.isNotEmpty || type.namedFields.isEmpty) {
      _fail(
        unit,
        offset,
        '@napi records must have named fields only and at least one field.',
      );
    }
    RecordAlias? alias;
    final instantiated = type.alias;
    if (instantiated != null) {
      final element = instantiated.element;
      var current = element;
      final visited = <TypeAliasElement>{};
      while (visited.add(current)) {
        if (current.typeParameters.isNotEmpty) {
          _fail(
            unit,
            offset,
            'Generic @napi record aliases are not supported.',
          );
        }
        final next = current.aliasedType.alias;
        if (next == null) break;
        current = next.element;
      }
      final name = element.name!;
      if (!element.isPublic) {
        _fail(unit, offset, '@napi record aliases must be public: "$name".');
      }
      if (javascriptKeywords.contains(name) ||
          _reservedTypeNames.contains(name) ||
          !RegExp(r'^[A-Za-z$][A-Za-z0-9_$]*$').hasMatch(name)) {
        _fail(
          unit,
          offset,
          '"$name" is a reserved or invalid TypeScript record alias name.',
        );
      }
      alias = (
        name: name,
        libraryUri: element.library.uri.toString(),
        nullable:
            element.aliasedType.nullabilitySuffix == NullabilitySuffix.question,
        documentationComment: element.documentationComment,
      );
      final previous = recordAliases[name];
      if (previous != null && previous.libraryUri != alias.libraryUri) {
        _fail(
          unit,
          offset,
          'Conflicting @napi record alias "$name" from '
          '"${previous.libraryUri}" and "${alias.libraryUri}".',
        );
      }
      recordAliases[name] = alias;
    }

    final fields = <RecordField>[];
    final fieldNames = <String>{};
    for (final field in type.namedFields) {
      final duplicate = !fieldNames.add(field.name);
      if (duplicate ||
          field.name.startsWith('_') ||
          _objectMemberNames.contains(field.name)) {
        final source = _recordSource(type, annotation);
        final nodes = source?.annotation.namedFields?.fields.where(
          (node) => node.name.lexeme == field.name,
        );
        final node = duplicate
            ? nodes?.skip(1).firstOrNull
            : nodes?.firstOrNull;
        _fail(
          node != null ? source!.unit : unit,
          node?.name.offset ?? offset,
          '${duplicate ? 'Duplicate' : 'Invalid'} @napi record field '
          '"${alias == null ? field.name : '${alias.name}.${field.name}'}".',
        );
      }
      final leaf = field.type;
      if (!_supportsLeafAliases(leaf)) {
        final source = _recordSource(type, annotation);
        final fieldName = alias == null
            ? field.name
            : '${alias.name}.${field.name}';
        final message = leaf.alias != null
            ? 'Type aliases are not supported in @napi record fields: "$fieldName".'
            : 'Unsupported @napi record field "$fieldName" type '
                  '"${leaf.getDisplayString()}". Use bool, int, double, String, or Uint8List '
                  '(optionally nullable).';
        final node = source?.annotation.namedFields?.fields
            .where((node) => node.name.lexeme == field.name)
            .firstOrNull;
        _fail(
          node != null ? source!.unit : unit,
          node?.type.offset ?? offset,
          message,
        );
      }
      fields.add((name: field.name, type: _valueType(leaf, offset)));
    }
    fields.sort((a, b) => a.name.compareTo(b.name));
    return ValueType(
      ValueKind.recordType,
      nullable: type.nullabilitySuffix == NullabilitySuffix.question,
      recordFields: List.unmodifiable(fields),
      recordAlias: alias,
    );
  }

  bool _supportsLeafAliases(DartType type) {
    if (!type.isDartCoreBool &&
        !type.isDartCoreInt &&
        !type.isDartCoreDouble &&
        !type.isDartCoreString &&
        !(type is InterfaceType &&
            type.element.name == 'Uint8List' &&
            type.element.library.uri.toString() == 'dart:typed_data')) {
      return false;
    }
    var alias = type.alias?.element;
    if (alias == null) return true;
    final visited = <TypeAliasElement>{};
    while (alias != null) {
      if (!visited.add(alias) || alias.typeParameters.isNotEmpty) return false;
      alias = alias.aliasedType.alias?.element;
    }
    return true;
  }

  ({FileResult unit, RecordTypeAnnotation annotation})? _recordSource(
    RecordType type,
    TypeAnnotation? annotation,
  ) {
    if (annotation is RecordTypeAnnotation) {
      return (unit: unit, annotation: annotation);
    }
    var element = type.alias?.element;
    if (element == null) return null;
    final visited = <TypeAliasElement>{};
    while (visited.add(element!)) {
      final next = element.aliasedType.alias?.element;
      if (next == null) break;
      element = next;
    }
    // This optional lookup improves field locations without changing admission.
    try {
      final library = unit.session.getParsedLibraryByElement(element.library);
      if (library is! ParsedLibraryResult) return null;
      final declaration = library.getFragmentDeclaration(element.firstFragment);
      final node = declaration?.node;
      if (node is GenericTypeAlias && node.type is RecordTypeAnnotation) {
        final sourceUnit = declaration!.parsedUnit;
        if (sourceUnit != null) {
          return (
            unit: sourceUnit,
            annotation: node.type as RecordTypeAnnotation,
          );
        }
      }
    } catch (_) {
      // Keep the signature location if the declaration cannot be recovered.
    }
    return null;
  }
}
