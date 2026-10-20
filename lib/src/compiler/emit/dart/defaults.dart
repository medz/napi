import 'dart:convert';

import '../../ir/defaults.dart';
import '../../ir/model.dart';
import '../../lowering/plan.dart';

Map<Uri, String> defaultImportPrefixes(
  Iterable<ParameterBinding> parameters,
  Iterable<ValueConversion> conversions,
) {
  final imports = <Uri, String>{};
  final defaults = [
    for (final parameter in parameters) ?parameter.defaultValue,
    for (final conversion in conversionGraph(conversions))
      if (conversion is ValueClassConversion)
        for (final field in conversion.fields) ?field.parameter?.defaultValue,
  ];
  for (final value in defaults) {
    for (final declaration in constantDefaultDeclarations(value)) {
      if (declaration.library == Uri.parse('dart:core')) continue;
      imports.putIfAbsent(
        declaration.library,
        () => '_napiDefault${imports.length}',
      );
    }
  }
  return imports;
}

String defaultDeclarationSource(
  DeclarationId declaration,
  Map<Uri, String> imports,
) => declaration.library == Uri.parse('dart:core')
    ? declaration.name
    : '${imports[declaration.library] ?? (throw StateError('Missing default import: ${declaration.library}'))}.${declaration.name}';

String renderDartDefault(
  ParameterBinding parameter,
  ValueConversion conversion, {
  String Function(DeclarationId)? declarationSource,
}) {
  final constant = parameter.defaultValue;
  if (constant != null && constant is! ScalarDefault) {
    // Dictionary's erased const type needs its boundary-facing static type.
    return '(${constantDefaultSource(constant, declarationSource: declarationSource)} as ${conversion.dartType})';
  }
  final value = (constant as ScalarDefault?)?.value;
  if (value == null) return 'null';
  if (value is String) return jsonEncode(value).replaceAll(r'$', r'\$');
  if (value is double) {
    if (value.isNaN) return 'double.nan';
    if (value.isInfinite) {
      return value.isNegative ? 'double.negativeInfinity' : 'double.infinity';
    }
  }
  if (value is int &&
      conversion is ScalarConversion &&
      conversion.kind == ScalarKind.doubleValue) {
    return value.toDouble().toString();
  }
  return value.toString();
}
