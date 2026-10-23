import 'dart:convert';
import 'dart:typed_data';

import 'model.dart';

/// Dart syntax for evaluated defaults, including constructors and const bindings.
/// This encoding also compares defaults; list/map actual types and map order
/// remain observable, while record named fields are ordered by name.
String constantDefaultSource(
  ConstantDefault value, {
  String Function(DeclarationId)? declarationSource,
}) {
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

    String typeSource(BindingType type) {
      final source = constantTypeSource(
        type,
        budget: budget,
        declarationSource: declarationSource,
      );
      if (source == null) {
        throw const FormatException('Constant type cannot be named publicly.');
      }
      return source;
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
        write('const <${typeSource(type.typeArguments.single)}>[');
        children(elements);
        write(']');
      case MapDefault(:final type, :final entries):
        if (type is! DeclaredType || type.typeArguments.length != 2) {
          throw const FormatException('Invalid Map default type.');
        }
        write('const <${type.typeArguments.map(typeSource).join(', ')}>{');
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
      case ObjectDefault(
        :final constructorType,
        :final constructor,
        :final positional,
        :final named,
      ):
        if (constructor.kind != DeclarationKind.constructor ||
            constructor.owner != constructorType.declaration ||
            constructorType.declaration.kind != DeclarationKind.classType ||
            constructor.name.startsWith('_') ||
            named.keys.any((name) => name.startsWith('_'))) {
          throw const FormatException('Constant constructor must be public.');
        }
        write('const ${typeSource(constructorType)}');
        if (constructor.name != 'new') write('.${constructor.name}');
        write('(');
        children(positional);
        var first = positional.isEmpty;
        for (final name in named.keys.toList()..sort()) {
          if (!first) write(', ');
          first = false;
          write('$name: ');
          emit(named[name]!, depth + 1);
        }
        write(')');
      case NamedObjectDefault(:final variable):
        final owner = variable.owner;
        if (declarationSource == null ||
            variable.name.startsWith('_') ||
            (owner == null
                ? variable.kind != DeclarationKind.variable
                : variable.kind != DeclarationKind.field ||
                      owner.owner != null ||
                      owner.name.startsWith('_') ||
                      !const {
                        DeclarationKind.classType,
                        DeclarationKind.enumType,
                        DeclarationKind.mixinType,
                        DeclarationKind.extensionType,
                      }.contains(owner.kind))) {
          throw const FormatException(
            'Constant object binding must be public.',
          );
        }
        write(
          owner == null
              ? declarationSource(variable)
              : '${declarationSource(owner)}.${variable.name}',
        );
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

/// Public user types require a declaration renderer for their import prefix.
String? constantTypeSource(
  BindingType type, {
  ConstantDefaultBudget? budget,
  int depth = 0,
  String Function(DeclarationId)? declarationSource,
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
          declarationSource: declarationSource,
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
          declarationSource: declarationSource,
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
          declarationSource: declarationSource,
        );
        if (text == null) return null;
        args.add(text);
      }
      return '${declaration.name}${args.isEmpty ? '' : '<${args.join(', ')}>'}$suffix';
    case DeclaredType(:final declaration, :final typeArguments)
        when declarationSource != null &&
            declaration.owner == null &&
            !declaration.name.startsWith('_') &&
            const {
              DeclarationKind.classType,
              DeclarationKind.enumType,
              DeclarationKind.mixinType,
              DeclarationKind.extensionType,
            }.contains(declaration.kind):
      final args = <String>[];
      for (final argument in typeArguments) {
        final text = constantTypeSource(
          argument,
          budget: budget,
          depth: depth + 1,
          declarationSource: declarationSource,
        );
        if (text == null) return null;
        args.add(text);
      }
      return '${declarationSource(declaration)}${args.isEmpty ? '' : '<${args.join(', ')}>'}$suffix';
    default:
      return null;
  }
}

/// Implicit null and a represented null prescribe the same omitted value.
/// A scalar int in a declared double context retains the existing normalization.
String parameterDefaultKey(
  ParameterBinding parameter, {
  String Function(DeclarationId)? declarationSource,
  String Function(String)? omissionKey,
}) {
  if (parameter.defaultOmissionKey case final key?) {
    return 'omitted:${omissionKey == null ? key : omissionKey(key)}';
  }
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
  return constantDefaultSource(
    value,
    declarationSource: declarationSource ?? constantDeclarationKey,
  );
}

/// Library identity matters when comparing otherwise identical default syntax.
String constantDeclarationKey(DeclarationId declaration) =>
    declaration.owner == null
    ? '${declaration.library}#${declaration.name}'
    : '${constantDeclarationKey(declaration.owner!)}.${declaration.name}';

/// Declarations named by reconstruction, excluding a factory's private result.
Iterable<DeclarationId> constantDefaultDeclarations(
  ConstantDefault value,
) sync* {
  Iterable<DeclarationId> typeDeclarations(BindingType type) sync* {
    if (type is DeclaredType) {
      if (type.declaration.library != Uri.parse('dart:core')) {
        yield type.declaration;
      }
      for (final argument in type.typeArguments) {
        yield* typeDeclarations(argument);
      }
    } else if (type is RecordTypeBinding) {
      for (final field in [...type.positional, ...type.named.values]) {
        yield* typeDeclarations(field);
      }
    }
  }

  final children = <ConstantDefault>[];
  switch (value) {
    case ScalarDefault():
      break;
    case ListDefault(:final type, :final elements):
      yield* typeDeclarations(type);
      children.addAll(elements);
    case MapDefault(:final type, :final entries):
      yield* typeDeclarations(type);
      for (final (key, value) in entries) {
        children.addAll([key, value]);
      }
    case RecordDefault(:final positional, :final named):
      children.addAll([...positional, ...named.values]);
    case ObjectDefault(:final constructorType, :final positional, :final named):
      yield* typeDeclarations(constructorType);
      children.addAll([...positional, ...named.values]);
    case NamedObjectDefault(:final variable):
      yield variable.owner ?? variable;
  }
  for (final child in children) {
    yield* constantDefaultDeclarations(child);
  }
}

String _scalarSource(Object? value) {
  if (value == null) return 'null';
  if (value is String) return jsonEncode(value).replaceAll(r'$', r'\$');
  if (value is double) {
    if (value.isNaN) {
      // double.nan itself can have either sign, depending on the host.
      final bytes = ByteData(16)
        ..setFloat64(0, value)
        ..setFloat64(8, double.nan);
      return (bytes.getUint8(0) ^ bytes.getUint8(8)) & 0x80 == 0
          ? 'double.nan'
          : '-double.nan';
    }
    if (value.isInfinite) {
      return value.isNegative ? 'double.negativeInfinity' : 'double.infinity';
    }
  }
  return value.toString();
}
