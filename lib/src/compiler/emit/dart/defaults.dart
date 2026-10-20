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

String emitDartDefaultResourceRetains(
  ValueConversion conversion,
  String value, {
  String operation = 'operation',
  String indent = '  ',
}) {
  if (!containsDefaultReference(conversion)) return '';
  final result = StringBuffer('$indent{\n');
  var next = 0;
  void emit(ValueConversion conversion, String value, String indent) {
    if (!containsDefaultReference(conversion)) return;
    final local = '_napiDefaultResource${next++}';
    result.writeln('${indent}final $local = $value;');
    if (conversion.nullable) {
      result.writeln('${indent}if ($local != null) {');
      indent += '  ';
    }
    switch (conversion) {
      case ReferenceConversion():
        result.writeln('$indent$operation.retain(_resourceControl($local));');
      case ListConversion(:final element) ||
          DictionaryConversion(value: final element):
        final item = '_napiDefaultResource${next++}';
        final values = conversion is DictionaryConversion
            ? '$local.values'
            : local;
        result.writeln('${indent}for (final $item in $values) {');
        emit(element, item, '$indent  ');
        result.writeln('$indent}');
      case MapConversion(:final key, :final value):
        final entry = '_napiDefaultResource${next++}';
        result.writeln('${indent}for (final $entry in $local.entries) {');
        emit(key, '$entry.key', '$indent  ');
        emit(value, '$entry.value', '$indent  ');
        result.writeln('$indent}');
      case RecordConversion():
        for (final field in conversion.fields.entries) {
          emit(field.value, '$local.${field.key}', indent);
        }
      default:
        throw StateError('Unsupported resource default conversion');
    }
    if (conversion.nullable) {
      indent = indent.substring(0, indent.length - 2);
      result.writeln('$indent}');
    }
  }

  emit(conversion, value, '$indent  ');
  result.writeln('$indent}');
  return result.toString();
}
