import 'dart:convert';

import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
// Keep constant storage inspection on the same pinned analyzer as the frontend.
// ignore: implementation_imports
import 'package:analyzer/src/dart/constant/value.dart' show DartObjectImpl;

import '../ir/defaults.dart';
import '../ir/model.dart' show ScalarDefault;

/// Compares defaults supplied by Dart itself, without naming private objects in
/// generated source. Unknown constant kinds stay unsupported.
String? constantStorageKey(DartObject value) {
  final budget = ConstantDefaultBudget();
  Object typeKey(DartType type, int depth) {
    budget.visit(depth);
    final nullable = type.nullabilitySuffix == NullabilitySuffix.question;
    return switch (type) {
      InterfaceType() => [
        type.element.library.uri.toString(),
        type.element.name,
        nullable,
        for (final argument in type.typeArguments) typeKey(argument, depth + 1),
      ],
      RecordType() => [
        'record',
        nullable,
        for (final field in type.positionalFields)
          typeKey(field.type, depth + 1),
        for (final field
            in type.namedFields.toList()
              ..sort((a, b) => a.name.compareTo(b.name)))
          [field.name, typeKey(field.type, depth + 1)],
      ],
      DynamicType() => 'dynamic',
      NeverType() => ['Never', nullable],
      _ => throw const FormatException('Unsupported constant type.'),
    };
  }

  Object? encode(DartObject? value, int depth) {
    budget.visit(depth);
    if (value == null || !value.hasKnownValue) {
      throw const FormatException('Unknown constant.');
    }
    if (value.isNull) return null;
    final scalar =
        value.toBoolValue() ??
        value.toIntValue() ??
        value.toDoubleValue() ??
        value.toStringValue();
    if (scalar != null) {
      final text = constantDefaultSource(ScalarDefault(scalar));
      budget.text(text.length);
      return [scalar is int ? 'int' : scalar.runtimeType.toString(), text];
    }
    final type = value.type;
    if (type == null) throw const FormatException('Unknown constant type.');
    final key = typeKey(type, depth);
    if (value.toListValue() case final elements?) {
      return [
        'list',
        key,
        for (final child in elements) encode(child, depth + 1),
      ];
    }
    if (value.toMapValue() case final entries?) {
      return [
        'map',
        key,
        for (final entry in entries.entries)
          [encode(entry.key, depth + 1), encode(entry.value, depth + 1)],
      ];
    }
    if (value.toSetValue() case final elements?) {
      return [
        'set',
        key,
        for (final child in elements) encode(child, depth + 1),
      ];
    }
    if (value.toRecordValue() case final record?) {
      return [
        'record',
        key,
        [for (final child in record.positional) encode(child, depth + 1)],
        [
          for (final name in record.named.keys.toList()..sort())
            [name, encode(record.named[name]!, depth + 1)],
        ],
      ];
    }
    if (value.toFunctionValue() != null ||
        value.toTypeValue() != null ||
        value.toSymbolValue() != null) {
      throw const FormatException('Unsupported constant storage.');
    }
    if (value is! DartObjectImpl || value.fields == null) {
      throw const FormatException('Unknown constant storage.');
    }
    final fields = value.fields!;
    return [
      'object',
      key,
      for (final name in fields.keys.toList()..sort())
        [name, encode(fields[name]!, depth + 1)],
    ];
  }

  try {
    final key = jsonEncode(encode(value, 0));
    if (key.length > ConstantDefaultBudget.maxText) {
      throw const ConstantDefaultLimit();
    }
    return key;
  } on FormatException {
    return null;
  }
}
