import 'dart:convert';

import '../../lowering/plan.dart';

/// Leaf engines plug into generated structural traversal without owning or
/// cloning containers. Production currently supplies only the scalar engine;
/// an identity adapter in the contract tests is not an opaque/reference engine.
abstract interface class StructuralLeafAdapter {
  String read(ValueConversion leaf, String value, String path);
  String write(ValueConversion leaf, String value, String path);
}

final class ScalarLeafAdapter implements StructuralLeafAdapter {
  const ScalarLeafAdapter();
  @override
  String read(ValueConversion leaf, String value, String path) =>
      'checkedScalar($value, ${jsonEncode(scalarPolicy(leaf as ScalarConversion))}, $path)';
  @override
  String write(ValueConversion leaf, String value, String path) {
    final scalar = leaf as ScalarConversion;
    return 'checkedScalar(${scalar.usesBigInt ? 'BigInt($value)' : value}, ${jsonEncode(scalarPolicy(scalar))}, $path)';
  }
}

Map<String, Object> scalarPolicy(ScalarConversion conversion) => {
  'context': conversion.context,
  'type': conversion.jsType,
  'nullable': conversion.nullable,
  'integer': conversion.kind == ScalarKind.integer,
};

final class StructuralBoundary {
  final String source;
  final String? read;
  final String? write;
  const StructuralBoundary(this.source, this.read, this.write);
}

StructuralBoundary emitStructuralBoundary(
  ValueConversion conversion, {
  required String prefix,
  StructuralLeafAdapter leafAdapter = const ScalarLeafAdapter(),
  bool generateRead = true,
  bool generateWrite = true,
}) {
  final code = StringBuffer();
  var next = 0;
  String emit(ValueConversion node, bool output) {
    final name = '${prefix}_${output ? 'write' : 'read'}${next++}';
    final children = switch (node) {
      ListConversion(:final element) => [element],
      RecordConversion() => node.fields.values.toList(),
      ScalarConversion() => <ValueConversion>[],
      ReferenceConversion() => throw StateError(
        'Nested class references are not supported',
      ),
    };
    final converters = [for (final child in children) emit(child, output)];
    code.writeln('function $name(value, path, state, depth) {');
    code.writeln('  visitStructure(state, path);');
    if (node.nullable) code.writeln('  if (value === null) return null;');
    switch (node) {
      case ReferenceConversion():
        throw StateError('Nested class references are not supported');
      case ScalarConversion():
        code.writeln(
          '  return ${output ? leafAdapter.write(node, 'value', 'path') : leafAdapter.read(node, 'value', 'path')};',
        );
      case ListConversion():
        code.writeln(
          '''  if (!Array.isArray(value)) throw new TypeError(path + ': expected an Array');
  enterStructure(value, path, state, depth);
  try {
    const length = checkArrayProperties(value, path, state);
    const result = [];
    for (let i = 0; i < length; i++) {
      const childPath = path + '[' + i + ']';
      const property = Object.getOwnPropertyDescriptor(value, String(i));
      if (!property || !Object.hasOwn(property, 'value')) {
        throw new TypeError(childPath + ': expected an own data property');
      }
      Object.defineProperty(result, String(i), {value: ${converters.single}(property.value, childPath, state, depth + 1), enumerable: true, writable: true, configurable: true});
    }
    return result;
  } finally { state.active.delete(value); }''',
        );
      case RecordConversion():
        final fields = node.fields.keys.toList();
        if (output) {
          code.writeln(
            '  if (!Array.isArray(value)) throw new TypeError(path + ": invalid private record ABI");',
          );
        } else {
          code.writeln('''  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new TypeError(path + ': expected a record object');
  }
  const prototype = Object.getPrototypeOf(value);
  if (prototype !== null && prototype !== Object.prototype) {
    throw new TypeError(path + ': expected a plain record object');
  }''');
        }
        code.writeln('  enterStructure(value, path, state, depth);\n  try {');
        if (output) {
          code.writeln('    const result = {};');
        } else {
          code.writeln(
            '    checkRecordProperties(value, ${jsonEncode(fields)}, path, state);',
          );
          code.writeln('    const result = [];');
        }
        for (final (index, field) in fields.indexed) {
          final key = jsonEncode(output ? '$index' : field);
          final pathKey = jsonEncode('.$field');
          code.writeln(
            '''    {
      const childPath = path + $pathKey;
      const property = Object.getOwnPropertyDescriptor(value, $key);
      if (!property || !Object.hasOwn(property, 'value')) {
        throw new TypeError(childPath + ': expected an own data property');
      }
      const child = ${converters[index]}(property.value, childPath, state, depth + 1);''',
          );
          if (output) {
            code.writeln(
              '      Object.defineProperty(result, ${jsonEncode(field)}, {value: child, enumerable: true, writable: true, configurable: true});',
            );
          } else {
            code.writeln(
              '      Object.defineProperty(result, ${jsonEncode('$index')}, {value: child, enumerable: true, writable: true, configurable: true});',
            );
          }
          code.writeln('    }');
        }
        code.writeln(
          '    return result;\n  } finally { state.active.delete(value); }',
        );
    }
    code.writeln('}');
    return name;
  }

  final read = generateRead ? emit(conversion, false) : null;
  final write = generateWrite ? emit(conversion, true) : null;
  return StructuralBoundary(code.toString(), read, write);
}

const structuralPolicy = r'''
function visitStructure(state, path) {
  if (++state.work > 10000) throw new RangeError(path + ': structural work limit (10000) exceeded');
}
function enterStructure(value, path, state, depth) {
  if (depth >= 64) throw new RangeError(path + ': structural depth limit (64) exceeded');
  if (state.active.has(value)) throw new TypeError(path + ': cyclic structural value');
  state.active.add(value);
}
function checkArrayProperties(value, path, state) {
  const prototype = Object.getPrototypeOf(value);
  if (prototype !== null && prototype !== Array.prototype) {
    throw new TypeError(path + ': expected a plain Array');
  }
  const length = value.length;
  if (typeof length !== 'number' || !Number.isInteger(length) || length < 0 || length > 0xffffffff) {
    throw new TypeError(path + '.length: expected an Array length');
  }
  if (length > 10000 - state.work) {
    throw new RangeError(path + ': structural work limit (10000) exceeded');
  }
  for (const key of Reflect.ownKeys(value)) {
    if (key === 'length') continue;
    const index = typeof key === 'string' ? Number(key) : NaN;
    if (!Number.isInteger(index) || index < 0 || index >= length || String(index) !== key) {
      throw new TypeError(path + '.' + String(key) + ': unknown Array property');
    }
  }
  return length;
}
function checkRecordProperties(value, fields, path, state) {
  let properties = 0;
  for (const key of Reflect.ownKeys(value)) {
    if (++properties > 10000 - state.work) {
      throw new RangeError(path + '.' + String(key) + ': structural work limit (10000) exceeded');
    }
    if (typeof key !== 'string' || !fields.includes(key)) {
      throw new TypeError(path + '.' + String(key) + ': unknown record field');
    }
  }
}
export function failStructure(path, message, range) {
  throw range ? new RangeError(path + ': ' + message) : new TypeError(path + ': ' + message);
}
''';
