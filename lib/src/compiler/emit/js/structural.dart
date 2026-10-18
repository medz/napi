import 'dart:convert';

import '../../lowering/plan.dart';

/// Leaf engines plug into generated structural traversal without owning or
/// cloning containers. Production supplies scalar and selected class engines.
abstract interface class StructuralLeafAdapter {
  String read(ValueConversion leaf, String value, String path);
  String write(ValueConversion leaf, String value, String path);
}

final class BoundaryLeafAdapter implements StructuralLeafAdapter {
  final bool resources;
  final bool bigintText;
  const BoundaryLeafAdapter({this.resources = false, this.bigintText = false});
  @override
  String read(ValueConversion leaf, String value, String path) {
    if (leaf is OpaqueConversion) return 'boxOpaque($value)';
    if (leaf is JsCollectionConversion) {
      return '\$jcAdmit($value, ${leaf.isMap}, ${leaf.nullable}, $path)';
    }
    if (leaf is SharedBytesConversion) {
      return '\$napiReadSharedBytes($value, ${leaf.nullable}, $path)';
    }
    if (leaf is BinaryConversion) {
      return '\$napiCopyBinary($value, ${leaf.kind.index}, ${leaf.nullable}, $path, true)';
    }
    if (leaf is ReferenceConversion) {
      return '${resources ? 'readResourceReference' : 'readReference'}($value, ${leaf.classId}, ${leaf.nullable}, $path${resources ? ', state.operation' : ''})';
    }
    final scalar = leaf as ScalarConversion;
    final checked =
        'checkedScalar($value, ${jsonEncode(scalarPolicy(scalar))}, $path)';
    return bigintText && scalar.usesBigInt ? 'readBigInt($checked)' : checked;
  }

  @override
  String write(ValueConversion leaf, String value, String path) {
    if (leaf is OpaqueConversion) return 'unboxOpaque($value)';
    if (leaf is JsCollectionConversion) {
      return '\$jcAdmit($value, ${leaf.isMap}, ${leaf.nullable}, $path)';
    }
    if (leaf is SharedBytesConversion) {
      return '\$napiReadSharedBytes($value, ${leaf.nullable}, $path)';
    }
    if (leaf is BinaryConversion) {
      return '\$napiAdoptBinary($value, ${leaf.kind.index}, ${leaf.nullable}, $path)';
    }
    if (leaf is ReferenceConversion) {
      return 'writeReference($value, ${leaf.classId}, $path, state.pending ??= new Set())';
    }
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
  StructuralLeafAdapter leafAdapter = const BoundaryLeafAdapter(),
  bool generateRead = true,
  bool generateWrite = true,
}) {
  final code = StringBuffer();
  var next = 0;
  final memo = <(ValueConversion, bool), String>{};
  String emit(ValueConversion node, bool output) {
    final key = (node, output);
    if (memo[key] case final name?) return name;
    final name = '${prefix}_${output ? 'write' : 'read'}${next++}';
    memo[key] = name;
    final children = switch (node) {
      ListConversion(:final element) => [element],
      MapConversion(:final key, :final value) => [key, value],
      DictionaryConversion(:final value) => [value],
      RecordConversion() => node.fields.values.toList(),
      ValueClassConversion() => [
        for (final field in node.fields) field.conversion,
      ],
      ScalarConversion() ||
      BinaryConversion() ||
      SharedBytesConversion() ||
      JsCollectionConversion() ||
      ReferenceConversion() ||
      OpaqueConversion() ||
      AbortSignalConversion() ||
      CallbackConversion() => <ValueConversion>[],
    };
    final converters = [for (final child in children) emit(child, output)];
    code.writeln('function $name(value, path, state, depth) {');
    code.writeln('  visitStructure(state, path);');
    if (node.nullable && (output || node is! OpaqueConversion)) {
      code.writeln('  if (value === null) return null;');
    }
    switch (node) {
      case CallbackConversion():
        throw StateError('Nested callback conversion is not supported.');
      case JsCollectionConversion():
        if (output) {
          code.writeln(
            "  if (value === false) throw new \$jcTypeError(path + ': expected a JS collection handle with this module and element policy');",
          );
        }
        code.writeln(
          '  return ${output ? leafAdapter.write(node, 'value', 'path') : leafAdapter.read(node, 'value', 'path')};',
        );
      case AbortSignalConversion():
        throw StateError('Nested AbortSignal conversion is not supported.');
      case OpaqueConversion() ||
          ReferenceConversion() ||
          ScalarConversion() ||
          BinaryConversion() ||
          SharedBytesConversion():
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
      case MapConversion():
        code.writeln(
          output
              ? "  if (!Array.isArray(value)) throw new TypeError(path + ': invalid private Map ABI');"
              : '  const length = mapLength(value, path);',
        );
        code.writeln('  enterStructure(value, path, state, depth);\n  try {');
        code.writeln(
          output
              ? '''    const entries = value;
    const result = new structureMapConstructor();'''
              : '''    const entries = snapshotMap(value, length, path, state);
    const result = [];''',
        );
        code.writeln(
          '''
    for (let i = 0; i < entries.length / 2; i++) {
      const keyPath = path + '[' + i + '].key';
      const key = ${converters[0]}(entries[2 * i], keyPath, state, depth + 1);
      const child = ${converters[1]}(entries[2 * i + 1], path + '[' + i + '].value', state, depth + 1);''',
        );
        if (output) {
          code.writeln(
            '''      if (structureApply(structureMapHas, result, [key])) {
        throw new TypeError(keyPath + ': duplicate converted Map key');
      }
      structureApply(structureMapSet, result, [key, child]);''',
          );
        } else {
          code.writeln(
            '''      Object.defineProperty(result, String(2 * i), {value: key, enumerable: true, writable: true, configurable: true});
      Object.defineProperty(result, String(2 * i + 1), {value: child, enumerable: true, writable: true, configurable: true});''',
          );
        }
        code.writeln(
          '    }\n    return result;\n  } finally { state.active.delete(value); }',
        );
      case DictionaryConversion():
        code.writeln(
          output
              ? "  if (!Array.isArray(value)) throw new TypeError(path + ': invalid private Dictionary ABI');"
              : '  checkDictionaryObject(value, path);',
        );
        code.writeln('  enterStructure(value, path, state, depth);\n  try {');
        code.writeln(
          output
              ? '''    const result = structureCreateDictionary(null);
    for (let i = 0; i < value.length / 2; i++) {
      const key = value[2 * i];
      const childPath = path + '[' + JSON.stringify(key) + ']';
      const child = ${converters.single}(value[2 * i + 1], childPath, state, depth + 1);
      Object.defineProperty(result, key, {value: child, enumerable: true, writable: true, configurable: true});'''
              : '''    const keys = dictionaryKeys(value, path, state);
    const result = [];
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      const childPath = path + '[' + JSON.stringify(key) + ']';
      const property = Object.getOwnPropertyDescriptor(value, key);
      if (!property || !Object.hasOwn(property, 'value')) {
        throw new TypeError(childPath + ': expected an own data property');
      }
      const child = ${converters.single}(property.value, childPath, state, depth + 1);
      Object.defineProperty(result, String(2 * i), {value: key, enumerable: true, writable: true, configurable: true});
      Object.defineProperty(result, String(2 * i + 1), {value: child, enumerable: true, writable: true, configurable: true});''',
        );
        code.writeln(
          '    }\n    return result;\n  } finally { state.active.delete(value); }',
        );
      case ValueClassConversion():
        final fields = node.fields.map((f) => f.name).toList();
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
        if (!output) {
          code.writeln(
            '    checkRecordProperties(value, ${jsonEncode(fields)}, path, state);',
          );
        }
        code.writeln(
          output ? '    const result = {};' : '    const result = [];',
        );
        for (final (index, field) in node.fields.indexed) {
          code.writeln(
            '''    {
      const childPath = path + ${jsonEncode('.${field.name}')};
      const property = Object.getOwnPropertyDescriptor(value, ${jsonEncode(output ? '$index' : field.name)});''',
          );
          if (!output && field.optional) {
            code.writeln(
              '''      if (property && !Object.hasOwn(property, 'value')) {
        throw new TypeError(childPath + ': expected an own data property');
      }
      const defaulted = !property || property.value === undefined;
      let child;
      if (defaulted) { visitStructure(state, childPath); child = null; }
      else { child = ${converters[index]}(property.value, childPath, state, depth + 1); }
      Object.defineProperty(result, ${jsonEncode('${2 * index}')}, {value: defaulted, enumerable: true, writable: true, configurable: true});
      Object.defineProperty(result, ${jsonEncode('${2 * index + 1}')}, {value: child, enumerable: true, writable: true, configurable: true});''',
            );
          } else {
            code.writeln(
              '''      if (!property || !Object.hasOwn(property, 'value')) {
        throw new TypeError(childPath + ': expected an own data property');
      }
      const child = ${converters[index]}(property.value, childPath, state, depth + 1);''',
            );
            if (!output) {
              code.writeln(
                '      Object.defineProperty(result, ${jsonEncode('${2 * index}')}, {value: false, enumerable: true, writable: true, configurable: true});',
              );
            }
            code.writeln(
              '      Object.defineProperty(result, ${jsonEncode(output ? field.name : '${2 * index + 1}')}, {value: child, enumerable: true, writable: true, configurable: true});',
            );
          }
          code.writeln('    }');
        }
        code.writeln(
          '    return result;\n  } finally { state.active.delete(value); }',
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

const dictionaryStructuralPolicy = r'''
const structureCreateDictionary = Object.create;
function checkDictionaryObject(value, path) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new TypeError(path + ': expected a Dictionary object');
  }
  const prototype = Object.getPrototypeOf(value);
  if (prototype !== null && prototype !== Object.prototype) {
    throw new TypeError(path + ': expected a plain Dictionary object');
  }
}
function dictionaryKeys(value, path, state) {
  const keys = Reflect.ownKeys(value);
  for (const key of keys) {
    if (typeof key !== 'string') throw new TypeError(path + ': expected string Dictionary keys');
  }
  if (keys.length > 10000 - state.work) {
    throw new RangeError(path + ': structural work limit (10000) exceeded');
  }
  return keys;
}
''';

const mapStructuralPolicy = r'''
// Capture intrinsics once; genuine cross-realm Maps work without consulting
// user-defined size, entries, iterator, has or set properties.
const structureMapConstructor = Map;
const structureApply = Reflect.apply;
const structureMapSize = Object.getOwnPropertyDescriptor(Map.prototype, 'size').get;
const structureMapEntries = Map.prototype.entries;
const structureMapNext = Object.getPrototypeOf(new Map().entries()).next;
const structureMapHas = Map.prototype.has;
const structureMapSet = Map.prototype.set;
function mapLength(value, path) {
  try { return structureApply(structureMapSize, value, []); }
  catch (_) { throw new TypeError(path + ': expected a Map'); }
}
function snapshotMap(value, length, path, state) {
  if (length > Math.floor((10000 - state.work) / 2)) {
    throw new RangeError(path + ': structural work limit (10000) exceeded');
  }
  const entries = [];
  const iterator = structureApply(structureMapEntries, value, []);
  for (let i = 0; i < length; i++) {
    const entry = structureApply(structureMapNext, iterator, []).value;
    Object.defineProperty(entries, String(2 * i), {value: entry[0], enumerable: true, writable: true, configurable: true});
    Object.defineProperty(entries, String(2 * i + 1), {value: entry[1], enumerable: true, writable: true, configurable: true});
  }
  return entries;
}
''';

const structuralPolicy =
    r'''
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
''' +
    structuralErrorPolicy;

const structuralErrorPolicy = r'''
export function failStructure(path, message, range) {
  throw range ? new RangeError(path + ': ' + message) : new TypeError(path + ': ' + message);
}
''';

/// Compiler-private envelopes preserve nullish leaves through JSAny containers.
const opaqueStructuralPolicy = r'''
export function boxOpaque(value) { return {__proto__: null, value}; }
export function unboxOpaque(envelope) { return envelope.value; }
''';
