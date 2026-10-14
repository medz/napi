import '../ir/model.dart';

final class BindingDiagnostic implements Exception {
  final String code;
  final String message;
  final SourceLocation? source;
  const BindingDiagnostic(this.code, this.message, [this.source]);
  @override
  String toString() => '$code${source == null ? '' : ' at $source'}: $message';
}

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

ValidatedModule validate(BindingModule module) {
  if (module.source.scheme != 'file' || module.functions.isEmpty) {
    throw const BindingDiagnostic(
      'NAPI_INPUT',
      'Provide a file library and at least one function.',
    );
  }
  final exports = <String>{};
  for (final function in module.functions) {
    void reject(String code, String message) =>
        throw BindingDiagnostic(code, message, function.source);
    if (function.declaration.library != module.source) {
      reject(
        'NAPI_LIBRARY',
        'Declaration must belong to the selected library.',
      );
    }
    if (!_identifier.hasMatch(function.declaration.name) ||
        function.declaration.name.startsWith('_') ||
        _reserved.contains(function.declaration.name)) {
      reject('NAPI_NAME', 'Expected a public Dart function identifier.');
    }
    if (!_identifier.hasMatch(function.exportName) ||
        _reserved.contains(function.exportName) ||
        function.exportName == 'then' ||
        function.exportName.startsWith('wasm_')) {
      reject('NAPI_NAME', 'Export name is not a supported public identifier.');
    }
    if (!exports.add(function.exportName)) {
      reject('NAPI_DUPLICATE', 'Duplicate export ${function.exportName}.');
    }
    final parameters = <String>{};
    for (final parameter in function.parameters) {
      if (!_identifier.hasMatch(parameter.name) ||
          _reserved.contains(parameter.name) ||
          !parameters.add(parameter.name)) {
        reject('NAPI_PARAMETER', 'Invalid or duplicate parameter name.');
      }
      if (parameter.presence != ParameterPresence.required) {
        reject(
          'NAPI_PRESENCE',
          'Presence-sensitive calls require a callable-global plan (#118); '
              'the foundation only generates required scalar functions.',
        );
      }
      if (parameter.type is! SafeIntType) {
        reject(
          'NAPI_TYPE',
          'No conversion engine for ${parameter.type.semantics.name}.',
        );
      }
    }
    if (function.result is! SafeIntType) {
      reject('NAPI_TYPE', 'The foundation only generates safe-int results.');
    }
  }
  return ValidatedModule._(module);
}
