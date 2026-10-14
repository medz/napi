import 'binding.dart';

final class BindingDiagnostic {
  const BindingDiagnostic({
    required this.code,
    required this.message,
    required this.source,
  });

  final String code;
  final String message;
  final SourceSpan source;

  @override
  String toString() => '$source: $code: $message';
}

final class BindingCompilationException implements Exception {
  BindingCompilationException(Iterable<BindingDiagnostic> diagnostics)
    : diagnostics = List.unmodifiable(diagnostics);

  final List<BindingDiagnostic> diagnostics;

  @override
  String toString() => diagnostics.join('\n');
}
