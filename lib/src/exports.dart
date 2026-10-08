import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/error.dart';
import 'package:path/path.dart' as path;

enum ValueKind {
  voidType,
  boolType,
  intType,
  doubleType,
  stringType,
  uint8ListType,
}

final class ValueType {
  const ValueType(this.kind, {this.nullable = false});

  final ValueKind kind;
  final bool nullable;
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
  });

  final String name;
  final List<Parameter> parameters;
  final ValueType returnType;
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

/// Resolves a Dart library and reads its annotated function signatures.
///
/// Parts belong to the same library and are included. Imports and re-exports
/// are not scanned for additional exports.
Future<List<Export>> readExports(String sourcePath) async {
  final absolutePath = path.normalize(path.absolute(sourcePath));
  if (!File(absolutePath).existsSync()) {
    throw ExportError(absolutePath, 1, 1, 'Dart source file does not exist.');
  }

  final contexts = AnalysisContextCollection(includedPaths: [absolutePath]);
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
      unit.unit.accept(_ExportVisitor(unit, exports, names));
    }
    if (exports.isEmpty) {
      throw ExportError(absolutePath, 1, 1, 'No @napi functions found.');
    }
    return List.unmodifiable(exports);
  } finally {
    await contexts.dispose();
  }
}

Never _fail(ResolvedUnitResult unit, int offset, String message) {
  final location = unit.lineInfo.getLocation(offset);
  throw ExportError(
    unit.path,
    location.lineNumber,
    location.columnNumber,
    message,
  );
}

class _ExportVisitor extends RecursiveAstVisitor<void> {
  _ExportVisitor(this.unit, this.exports, this.names);

  final ResolvedUnitResult unit;
  final List<Export> exports;
  final Set<String> names;

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
    if (expression.body.isAsynchronous || expression.body.isGenerator) {
      _fail(
        unit,
        expression.body.offset,
        '@napi functions must be synchronous and cannot be generators.',
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
          type: _valueType(parameter.type, parameterNode.offset),
        ),
      );
    }

    exports.add(
      Export(
        name: name,
        parameters: List.unmodifiable(parameters),
        returnType: _valueType(
          element.returnType,
          declaration.returnType?.offset ?? declaration.name.offset,
          allowVoid: true,
        ),
      ),
    );
  }

  ValueType _valueType(DartType type, int offset, {bool allowVoid = false}) {
    if (type.alias != null) {
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
}
