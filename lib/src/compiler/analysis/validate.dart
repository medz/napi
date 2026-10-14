import '../ir/binding.dart';
import '../ir/diagnostic.dart';

/// Validate the bounded foundation contract before any emitter is invoked.
void validateModule(BindingModule module) {
  final diagnostics = <BindingDiagnostic>[];
  final names = <String>{};
  void reject(String code, String message, SourceSpan source) {
    diagnostics.add(
      BindingDiagnostic(code: code, message: message, source: source),
    );
  }

  void checkType(
    PrimitiveTypePolicy type,
    SourceSpan source, {
    bool result = false,
  }) {
    if (type.nullable) {
      reject(
        'unsupported_nullable',
        'Nullable bindings require the conversion frontend in #109.',
        source,
      );
    }
    if (!result && type.kind == PrimitiveKind.voidType) {
      reject(
        'unsupported_void_parameter',
        'void is supported only as a result.',
        source,
      );
    }
  }

  for (final function in module.functions) {
    if (!names.add(function.publicName)) {
      reject(
        'duplicate_public_name',
        'Duplicate export ${function.publicName}.',
        function.source,
      );
    }
    if (!RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(function.publicName) ||
        _reserved.contains(function.publicName)) {
      reject(
        'invalid_public_name',
        'Export ${function.publicName} is not a supported JavaScript identifier.',
        function.source,
      );
    }
    if (function.publicName == 'then') {
      reject(
        'reserved_module_export',
        'The callable export then interferes with ESM dynamic-import resolution.',
        function.source,
      );
    }
    if (function.dartName.startsWith('_')) {
      reject(
        'private_declaration',
        'Private declarations cannot be imported by the generated bridge.',
        function.source,
      );
    }
    for (final parameter in function.parameters) {
      checkType(parameter.type, parameter.source);
    }
    checkType(function.returnType, function.source, result: true);
  }
  if (diagnostics.isNotEmpty) throw BindingCompilationException(diagnostics);
}

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
  'eval',
  'arguments',
};
