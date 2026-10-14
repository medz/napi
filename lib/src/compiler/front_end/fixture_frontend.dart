import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/error.dart';

import '../ir/binding.dart';
import '../ir/diagnostic.dart';
import 'front_end.dart';
import 'wasm_sdk_profile.dart';

/// Minimal resolved declaration producer for executable foundation fixtures.
///
/// Only explicitly selected top-level, explicitly typed synchronous functions
/// with required positional scalar parameters are accepted. Annotations are
/// deliberately not interpreted by this fixture-only frontend.
final class FixtureFrontend implements BindingFrontend {
  @override
  Future<BindingModule> resolve({
    required String path,
    required Iterable<String> functionNames,
  }) async {
    final file = File.fromUri(File(path).absolute.uri.normalizePath());
    final uri = file.uri;
    if (!await file.exists()) {
      throw BindingCompilationException([
        BindingDiagnostic(
          code: 'source_not_found',
          message: 'Fixture source does not exist: ${file.path}.',
          source: SourceSpan(
            uri: uri,
            offset: 0,
            length: 0,
            line: 1,
            column: 1,
          ),
        ),
      ]);
    }
    final collection = WasmSdkProfile.load(sourceUri: uri)
        .createContext(file.path);
    try {
      final result = await collection
          .contextFor(file.path)
          .currentSession
          .getResolvedUnit(file.path);
      if (result is! ResolvedUnitResult) {
        throw BindingCompilationException([
          BindingDiagnostic(
            code: 'unresolved_library',
            message: 'Cannot resolve ${file.path}.',
            source: SourceSpan(
              uri: uri,
              offset: 0,
              length: 0,
              line: 1,
              column: 1,
            ),
          ),
        ]);
      }
      SourceSpan span(int offset, int length) {
        final location = result.lineInfo.getLocation(offset);
        return SourceSpan(
          uri: uri,
          offset: offset,
          length: length,
          line: location.lineNumber,
          column: location.columnNumber,
        );
      }

      final diagnostics = <BindingDiagnostic>[];
      void reject(String code, String message, SourceSpan source) {
        diagnostics.add(
          BindingDiagnostic(code: code, message: message, source: source),
        );
      }

      for (final error in result.diagnostics) {
        if (error.diagnosticCode.severity == DiagnosticSeverity.ERROR) {
          reject(
            'dart_analysis_error',
            error.message,
            span(error.offset, error.length),
          );
        }
      }
      if (result.unit.directives.whereType<PartOfDirective>().isNotEmpty) {
        reject(
          'unsupported_part',
          'Select a library file, not a part file.',
          span(0, 0),
        );
      }
      final selected = functionNames.toList();
      if (selected.isEmpty) {
        reject(
          'empty_selection',
          'Select at least one fixture function explicitly.',
          span(0, 0),
        );
      }
      final functions = <FunctionBinding>[];
      for (final name in selected) {
        final matches = result.unit.declarations
            .whereType<FunctionDeclaration>()
            .where((node) => node.name.lexeme == name)
            .toList();
        if (matches.length != 1) {
          reject(
            'missing_function',
            'Expected one top-level function named $name in this library.',
            span(0, 0),
          );
          continue;
        }
        final node = matches.single;
        final source = span(node.offset, node.length);
        final expression = node.functionExpression;
        if (node.isGetter ||
            node.isSetter ||
            node.externalKeyword != null ||
            expression.typeParameters != null ||
            expression.body.isAsynchronous ||
            expression.body.isGenerator) {
          reject(
            'unsupported_function',
            'Only synchronous non-generic top-level functions with a Dart body are supported.',
            source,
          );
          continue;
        }
        final element = node.declaredFragment?.element;
        if (node.returnType == null || element == null) {
          reject(
            'explicit_type_required',
            'Fixture functions need an explicit result type.',
            source,
          );
          continue;
        }
        PrimitiveTypePolicy? policy(
          DartType type,
          SourceSpan source, {
          bool resultType = false,
        }) {
          if (type.nullabilitySuffix != NullabilitySuffix.none) {
            reject(
              'unsupported_nullable',
              'Nullable bindings are not implemented by the foundation.',
              source,
            );
            return null;
          }
          final kind = type.isDartCoreInt
              ? PrimitiveKind.integer
              : type.isDartCoreDouble
              ? PrimitiveKind.doublePrecision
              : type.isDartCoreBool
              ? PrimitiveKind.boolean
              : type.isDartCoreString
              ? PrimitiveKind.string
              : type is VoidType && resultType
              ? PrimitiveKind.voidType
              : null;
          if (kind == null) {
            reject(
              'unsupported_type',
              'Unsupported foundation type ${type.getDisplayString()}.',
              source,
            );
            return null;
          }
          return PrimitiveTypePolicy(kind);
        }

        final returnType = policy(
          element.returnType,
          span(node.returnType!.offset, node.returnType!.length),
          resultType: true,
        );
        final parameters = <ParameterBinding>[];
        var valid = returnType != null;
        for (final parameter in expression.parameters!.parameters) {
          final parameterSource = span(parameter.offset, parameter.length);
          if (!parameter.isRequiredPositional ||
              !parameter.isExplicitlyTyped ||
              parameter.functionTypedSuffix != null) {
            reject(
              'unsupported_parameter',
              'Fixture parameters must be explicitly typed, required and positional.',
              parameterSource,
            );
            valid = false;
            continue;
          }
          final type = policy(
            parameter.declaredFragment!.element.type,
            parameterSource,
          );
          if (type == null) {
            valid = false;
            continue;
          }
          parameters.add(
            ParameterBinding(
              name: parameter.name!.lexeme,
              type: type,
              source: parameterSource,
            ),
          );
        }
        if (valid) {
          functions.add(
            FunctionBinding(
              identity: DeclarationIdentity(libraryUri: uri, name: name),
              source: source,
              dartName: name,
              publicName: name,
              parameters: parameters,
              returnType: returnType!,
            ),
          );
        }
      }
      if (diagnostics.isNotEmpty) {
        throw BindingCompilationException(diagnostics);
      }
      return BindingModule(sourceUri: uri, functions: functions);
    } finally {
      await collection.dispose();
    }
  }
}
