import 'dart:convert';
import 'dart:typed_data';

import 'model.dart';

/// Canonical Dart syntax for a completely represented built-in constant graph.
/// This encoding also compares defaults; list/map actual types and map order
/// remain observable, while record named fields are ordered by name.
String constantDefaultSource(ConstantDefault value) {
  if (value is ScalarDefault) return _scalarSource(value.value);
  final budget = ConstantDefaultBudget();
  final output = StringBuffer();
  void write(String text) {
    budget.text(text.length);
    output.write(text);
  }

  void emit(ConstantDefault value, int depth) {
    budget.visit(depth, leaf: value is ScalarDefault);
    void children(Iterable<ConstantDefault> values) {
      var first = true;
      for (final child in values) {
        if (!first) write(', ');
        first = false;
        emit(child, depth + 1);
      }
    }

    switch (value) {
      case ScalarDefault(:final value):
        if (value is String && value.length > ConstantDefaultBudget.maxText) {
          throw const ConstantDefaultLimit();
        }
        write(_scalarSource(value));
      case ListDefault(:final type, :final elements):
        if (type is! DeclaredType || type.typeArguments.length != 1) {
          throw const FormatException('Invalid List default type.');
        }
        write(
          'const <${constantTypeSource(type.typeArguments.single, budget: budget)}>[',
        );
        children(elements);
        write(']');
      case MapDefault(:final type, :final entries):
        if (type is! DeclaredType || type.typeArguments.length != 2) {
          throw const FormatException('Invalid Map default type.');
        }
        write(
          'const <${type.typeArguments.map((t) => constantTypeSource(t, budget: budget)).join(', ')}>{',
        );
        var first = true;
        for (final (key, value) in entries) {
          if (!first) write(', ');
          first = false;
          emit(key, depth + 1);
          write(': ');
          emit(value, depth + 1);
        }
        write('}');
      case RecordDefault(:final positional, :final named):
        write('const (');
        children(positional);
        var first = positional.isEmpty;
        for (final name in named.keys.toList()..sort()) {
          if (!first) write(', ');
          first = false;
          write('$name: ');
          emit(named[name]!, depth + 1);
        }
        if (positional.length == 1 && named.isEmpty) write(',');
        write(')');
    }
  }

  emit(value, 0);
  return output.toString();
}

/// Match structural conversion's work/depth bounds, also bounding generated text.
/// Count expanded visits, so repeated references cannot hide exponential work.
final class ConstantDefaultBudget {
  static const maxText = 1024 * 1024;
  var _visits = 0;
  var _text = 0;
  void visit(int depth, {bool leaf = false}) {
    if (++_visits > 10000 || depth > 64 || (!leaf && depth == 64)) {
      throw const ConstantDefaultLimit();
    }
  }

  void text(int length) {
    if ((_text += length) > maxText) throw const ConstantDefaultLimit();
  }
}

final class ConstantDefaultLimit implements Exception {
  const ConstantDefaultLimit();
  @override
  String toString() =>
      'Structural default exceeds 10000 expanded values/type nodes, depth 64, or 1 MiB of generated text.';
}

/// Only library-independent types can be reconstructed in this first slice.
String? constantTypeSource(
  BindingType type, {
  ConstantDefaultBudget? budget,
  int depth = 0,
}) {
  budget ??= ConstantDefaultBudget();
  budget.visit(
    depth,
    leaf:
        type is! RecordTypeBinding &&
        (type is! DeclaredType || type.typeArguments.isEmpty),
  );
  final suffix = type.nullability == TypeNullability.nullable ? '?' : '';
  if (type.nullability == TypeNullability.legacy) return null;
  switch (type) {
    case SafeIntType():
      return 'int$suffix';
    case NeverType():
      return 'Never$suffix';
    case DynamicType():
      return 'dynamic';
    case RecordTypeBinding(:final positional, :final named):
      final fields = <String>[];
      for (final field in positional) {
        final text = constantTypeSource(
          field,
          budget: budget,
          depth: depth + 1,
        );
        if (text == null) return null;
        fields.add(text);
      }
      final names = named.keys.toList()..sort();
      final namedFields = <String>[];
      for (final name in names) {
        final text = constantTypeSource(
          named[name]!,
          budget: budget,
          depth: depth + 1,
        );
        if (text == null) return null;
        namedFields.add('$text $name');
      }
      if (namedFields.isNotEmpty) fields.add('{${namedFields.join(', ')}}');
      return '(${fields.join(', ')}${positional.length == 1 && named.isEmpty ? ',' : ''})$suffix';
    case DeclaredType(:final declaration, :final typeArguments)
        when declaration.library == Uri.parse('dart:core') &&
            declaration.owner == null &&
            declaration.kind == DeclarationKind.classType &&
            const {
              'bool',
              'int',
              'double',
              'num',
              'String',
              'Null',
              'Object',
              'BigInt',
              'List',
              'Map',
              'Set',
              'Record',
            }.contains(declaration.name):
      final args = <String>[];
      for (final argument in typeArguments) {
        final text = constantTypeSource(
          argument,
          budget: budget,
          depth: depth + 1,
        );
        if (text == null) return null;
        args.add(text);
      }
      return '${declaration.name}${args.isEmpty ? '' : '<${args.join(', ')}>'}$suffix';
    default:
      return null;
  }
}

/// Implicit null and a represented null prescribe the same omitted value.
/// A scalar int in a declared double context retains the existing normalization.
String parameterDefaultKey(ParameterBinding parameter) {
  final value = parameter.defaultValue;
  if (value == null) return 'null';
  if (value case ScalarDefault(value: final double n) when n.isNaN) {
    return 'double.nan';
  }
  if (value case ScalarDefault(value: final int n)) {
    if (parameter.type case DeclaredType(:final declaration)
        when declaration.library == Uri.parse('dart:core') &&
            declaration.name == 'double') {
      return _scalarSource(n.toDouble());
    }
  }
  return constantDefaultSource(value);
}

String _scalarSource(Object? value) {
  if (value == null) return 'null';
  if (value is String) return jsonEncode(value).replaceAll(r'$', r'\$');
  if (value is double) {
    if (value.isNaN) {
      final bytes = ByteData(8)..setFloat64(0, value);
      return bytes.getUint8(0) & 0x80 == 0 ? 'double.nan' : '-double.nan';
    }
    if (value.isInfinite) {
      return value.isNegative ? 'double.negativeInfinity' : 'double.infinity';
    }
  }
  return value.toString();
}
