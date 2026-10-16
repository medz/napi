import 'dart:convert';

import '../emit/dart/entrypoint.dart' show renderDartDefault;
import '../ir/model.dart' show ParameterKind;
import '../lowering/plan.dart';

String _quote(String value) => jsonEncode(value).replaceAll(r'$', r'\$');

String nativeScalarReader(ScalarConversion value) => switch (value.kind) {
  ScalarKind.integer => value.bigint ? 'integerBigInt' : 'integer',
  ScalarKind.boolean => 'boolean',
  ScalarKind.string => 'string',
  ScalarKind.doubleValue => 'doubleValue',
  ScalarKind.bigInteger => 'bigInteger',
};

String nativeScalarWriter(ScalarConversion value) => switch (value.kind) {
  ScalarKind.integer => value.bigint ? 'integerBigIntResult' : 'integerResult',
  ScalarKind.boolean => 'booleanResult',
  ScalarKind.string => 'stringResult',
  ScalarKind.doubleValue => 'doubleResult',
  ScalarKind.bigInteger => 'bigIntegerResult',
};

/// Typed traversal owns only callback-scoped JS handles and ordinary Dart values.
final class NativeStructuralEmitter {
  final _code = StringBuffer();
  var _next = 0;
  final _reads = Map<ValueConversion, String>.identity();
  final _writes = Map<ValueConversion, String>.identity();
  final _normalizers = Map<ValueConversion, String>.identity();
  final _materializers = Map<ValueConversion, String>.identity();
  final _outputSnapshots = Map<ValueConversion, String>.identity();
  final _snapshotWriters = Map<ValueConversion, String>.identity();

  String read(ValueConversion conversion) {
    if (!containsValueClass(conversion)) return _emit(conversion, false);
    final normalize = _normalize(conversion);
    final materialize = _materialize(conversion);
    final name = '_readNativeValueRoot${_next++}';
    _code.writeln(
      '''${conversion.dartType} $name(Pointer<Void> env, Pointer<Void> value, _NativeReadState state, String path, int depth) {
  final normalized = $normalize(env, value, state, path, depth);
  return $materialize(normalized, path);
}''',
    );
    return name;
  }

  String write(ValueConversion conversion) {
    if (!containsValueClass(conversion)) return _emit(conversion, true);
    if (_writes[conversion] case final previous?) return previous;
    final snapshot = _snapshotOutput(conversion);
    final hostWrite = _writeSnapshot(conversion);
    final name = '_writeNativeValueRoot${_next++}';
    _writes[conversion] = name;
    _code.writeln(
      '''int $name(Pointer<Void> env, ${conversion.dartType} value, _NativeWriteState state, String path, int depth) {
  final snapshot = $snapshot(value, _NativeWriteState(), path, depth);
  return $hostWrite(env, snapshot, state, path);
}''',
    );
    return name;
  }

  String get source => _code.toString();

  String _emit(ValueConversion conversion, bool output) {
    final cache = output ? _writes : _reads;
    final previous = cache[conversion];
    if (previous != null) return previous;
    final name = '_${output ? 'write' : 'read'}NativeStructure${_next++}';
    cache[conversion] = name;
    final children = switch (conversion) {
      ListConversion(:final element) => [element],
      MapConversion(:final key, :final value) => [key, value],
      DictionaryConversion(:final value) => [value],
      RecordConversion() => conversion.fields.values.toList(),
      ValueClassConversion() => [
        for (final field in conversion.fields) field.conversion,
      ],
      ScalarConversion() || ReferenceConversion() => <ValueConversion>[],
    };
    final functions = [for (final child in children) _emit(child, output)];
    _code.writeln(
      output
          ? 'int $name(Pointer<Void> env, ${conversion.dartType} value, _NativeWriteState state, String path, int depth) {'
          : '${conversion.dartType} $name(Pointer<Void> env, Pointer<Void> value, _NativeReadState state, String path, int depth) {',
    );
    _code.writeln('  state.visit(path);');
    if (conversion.nullable) {
      _code.writeln(
        output
            ? '  if (value == null) return _api.nullResult(env);'
            : '  if (_api.isNull(env, value)) return null;',
      );
    }
    switch (conversion) {
      case ReferenceConversion():
        if (output) {
          _code.writeln(
            '  return _api.referenceResult(env, value, ${conversion.classId}, path, state.pending);',
          );
        } else {
          _code.writeln(
            '  final object = _api.ownerValue(env, value, path, ${conversion.classId});',
          );
          _code.writeln(
            "  if (object is! target.${conversion.classBinding.callPath}) throw NapiTypeError('\$path: expected ${conversion.classBinding.exportName}');",
          );
          _code.writeln('  return object;');
        }
      case ScalarConversion():
        final context =
            output &&
                conversion.kind == ScalarKind.integer &&
                !conversion.usesBigInt
            ? ', path'
            : '';
        _code.writeln(
          output
              ? '  return _api.${nativeScalarWriter(conversion)}(env, value$context);'
              : '  return _api.${nativeScalarReader(conversion)}(env, value, path${conversion.nullable ? ', nullable: true' : ''});',
        );
      case ListConversion(:final element):
        if (output) {
          _code.writeln('''  state.enter(value, path, depth);
  try {
    final length = value.length;
    if (length < 0 || length > 0xffffffff) throw NapiTypeError('\$path.length: expected an Array length');
    if (length > 10000 - state.work) throw NapiRangeError('\$path: structural work limit (10000) exceeded');
    final result = _api.createContainer(env, true, length);
    for (var i = 0; i < length; i++) {
      final child = ${functions.single}(env, value[i], state, '\$path[\$i]', depth + 1);
      _api.defineOwnValue(env, result, '\$i', child);
    }
    return result;
  } finally { state.leave(value); }''');
        } else {
          _code.writeln(
            '''  final length = _api.inspectShape(env, value, true, const [], path, 10000 - state.work, depth, state.contains(env, value));
  state.active.add(value);
  try {
    final result = <${element.dartType}>[];
    for (var i = 0; i < length; i++) {
      final childPath = '\$path[\$i]';
      final child = _api.readOwnValue(env, value, '\$i', childPath);
      result.add(${functions.single}(env, child, state, childPath, depth + 1));
    }
    return result;
  } finally { state.active.removeLast(); }''',
          );
        }
      case MapConversion(:final key, :final value):
        if (output) {
          _code.writeln('''  state.enter(value, path, depth);
  try {
    final length = value.length;
    if (length < 0 || length > 0xffffffff) throw NapiTypeError('\$path.length: expected a Map length');
    if (length > (10000 - state.work) ~/ 2) throw NapiRangeError('\$path: structural work limit (10000) exceeded');
    final entries = <(${key.dartType}, ${value.dartType})>[];
    final iterator = value.entries.iterator;
    for (var i = 0; i < length; i++) {
      if (!iterator.moveNext()) throw NapiTypeError('\$path: Map length changed during iteration');
      final entry = iterator.current;
      entries.add((entry.key, entry.value));
    }
    if (iterator.moveNext()) throw NapiTypeError('\$path: Map length changed during iteration');
    final result = _api.createMap(env);
    for (var i = 0; i < entries.length; i++) {
      final keyPath = '\$path[\$i].key';
      final key = ${functions[0]}(env, entries[i].\$1, state, keyPath, depth + 1);
      final child = ${functions[1]}(env, entries[i].\$2, state, '\$path[\$i].value', depth + 1);
      _api.checkedInsertMap(env, result, key, child, keyPath);
    }
    return result;
  } finally { state.leave(value); }''');
        } else {
          _code.writeln(
            '''  final (entries, length) = _api.snapshotMap(env, value, path, 10000 - state.work, depth, state.contains(env, value));
  state.active.add(value);
  try {
    final result = <${key.dartType}, ${value.dartType}>{};
    for (var i = 0; i < length; i++) {
      final keyPath = '\$path[\$i].key';
      final rawKey = _api.readOwnValue(env, entries, '\${2 * i}', keyPath);
      final key = ${functions[0]}(env, rawKey, state, keyPath, depth + 1);
      final valuePath = '\$path[\$i].value';
      final rawValue = _api.readOwnValue(env, entries, '\${2 * i + 1}', valuePath);
      final child = ${functions[1]}(env, rawValue, state, valuePath, depth + 1);
      if (result.containsKey(key)) throw NapiTypeError('\$keyPath: duplicate converted Map key');
      result[key] = child;
    }
    return result;
  } finally { state.active.removeLast(); }''',
          );
        }
      case DictionaryConversion(:final value):
        if (output) {
          _code.writeln('''  state.enter(value, path, depth);
  try {
    final length = value.length;
    if (length < 0 || length > 0xffffffff) throw NapiTypeError('\$path.length: expected a Dictionary length');
    if (length > 10000 - state.work) throw NapiRangeError('\$path: structural work limit (10000) exceeded');
    final entries = <(String, ${value.dartType})>[];
    final keys = <String>{};
    final iterator = value.entries.iterator;
    for (var i = 0; i < length; i++) {
      if (!iterator.moveNext()) throw NapiTypeError('\$path: Dictionary length changed during iteration');
      final entry = iterator.current;
      final key = entry.key;
      final child = entry.value;
      if (!keys.add(key)) throw NapiTypeError('\$path[\${jsonEncode(key)}]: duplicate Dictionary key');
      entries.add((key, child));
    }
    if (iterator.moveNext()) throw NapiTypeError('\$path: Dictionary length changed during iteration');
    final result = _api.createDictionary(env);
    for (final entry in entries) {
      final key = entry.\$1;
      final child = ${functions.single}(env, entry.\$2, state, '\$path[\${jsonEncode(key)}]', depth + 1);
      _api.defineOwnValue(env, result, key, child);
    }
    return result;
  } finally { state.leave(value); }''');
        } else {
          _code.writeln(
            '''  final (keys, length) = _api.dictionaryKeys(env, value, path, 10000 - state.work, depth, state.contains(env, value));
  state.active.add(value);
  try {
    final result = <String, ${value.dartType}>{};
    for (var i = 0; i < length; i++) {
      final rawKey = _api.readOwnValue(env, keys, '\$i', path);
      final key = _api.string(env, rawKey, path);
      final childPath = '\$path[\${jsonEncode(key)}]';
      final raw = _api.readOwnValue(env, value, key, childPath);
      result[key] = ${functions.single}(env, raw, state, childPath, depth + 1);
    }
    return napi.Dictionary<${value.dartType}>(result);
  } finally { state.active.removeLast(); }''',
          );
        }
      case ValueClassConversion():
        if (!output) throw StateError('Value inputs require normalization');
        _code.writeln('  state.enter(value, path, depth);\n  try {');
        for (final (index, field) in conversion.fields.indexed) {
          final member =
              field.binding.callPath ?? field.binding.declaration.name;
          _code.writeln('    final raw$index = value.$member;');
        }
        _code.writeln(
          '    final result = _api.createContainer(env, false, 0);',
        );
        for (final (index, field) in conversion.fields.indexed) {
          final path = 'path + ${_quote('.${field.name}')}';
          _code.writeln(
            '    final child$index = ${functions[index]}(env, raw$index, state, $path, depth + 1);',
          );
          _code.writeln(
            '    _api.defineOwnValue(env, result, ${_quote(field.name)}, child$index);',
          );
        }
        _code.writeln(
          '    return result;\n  } finally { state.leave(value); }',
        );
      case RecordConversion():
        final fields = conversion.fields.keys.toList();
        if (output) {
          _code.writeln('''  state.enter(value, path, depth);
  try {
    final result = _api.createContainer(env, false, 0);''');
        } else {
          final keys = fields.map(_quote).join(', ');
          _code.writeln(
            '''  _api.inspectShape(env, value, false, const [$keys], path, 10000 - state.work, depth, state.contains(env, value));
  state.active.add(value);
  try {''',
          );
        }
        for (final (index, field) in fields.indexed) {
          final path = 'path + ${_quote('.$field')}';
          if (output) {
            _code.writeln(
              '    final child$index = ${functions[index]}(env, value.$field, state, $path, depth + 1);',
            );
            _code.writeln(
              '    _api.defineOwnValue(env, result, ${_quote(field)}, child$index);',
            );
          } else {
            _code.writeln(
              '    final raw$index = _api.readOwnValue(env, value, ${_quote(field)}, $path);',
            );
            _code.writeln(
              '    final child$index = ${functions[index]}(env, raw$index, state, $path, depth + 1);',
            );
          }
        }
        if (output) {
          _code.writeln('    return result;');
        } else {
          final entries = <String>[];
          for (var index = 0; index < conversion.positional.length; index++) {
            entries.add('child$index');
          }
          for (final (index, field) in conversion.named.keys.indexed) {
            entries.add('$field: child${conversion.positional.length + index}');
          }
          final trailing = entries.length == 1 && conversion.named.isEmpty
              ? ','
              : '';
          _code.writeln('    return (${entries.join(', ')}$trailing);');
        }
        _code.writeln(
          output
              ? '  } finally { state.leave(value); }'
              : '  } finally { state.active.removeLast(); }',
        );
    }
    _code.writeln('}');
    return name;
  }

  // Match the Wasm Dart serialization phase before any host scalar checks,
  // reference identity claims or JavaScript Map insertion. Snapshots contain only
  // plain Dart lists and typed leaves; no business getter runs in the host pass.
  String _snapshotOutput(ValueConversion conversion) {
    if (_outputSnapshots[conversion] case final previous?) return previous;
    final name = '_snapshotNativeOutput${_next++}';
    _outputSnapshots[conversion] = name;
    final functions = [
      for (final child in _children(conversion)) _snapshotOutput(child),
    ];
    _code.writeln(
      'Object? $name(${conversion.dartType} value, _NativeWriteState state, String path, int depth) {',
    );
    _code.writeln('  state.visit(path);');
    if (conversion.nullable) _code.writeln('  if (value == null) return null;');
    switch (conversion) {
      case ScalarConversion() || ReferenceConversion():
        _code.writeln('  return value;');
      case ListConversion():
        _code.writeln('''  state.enter(value, path, depth);
  try {
    final length = value.length;
    if (length < 0 || length > 0xffffffff) throw NapiTypeError('\$path.length: expected an Array length');
    if (length > 10000 - state.work) throw NapiRangeError('\$path: structural work limit (10000) exceeded');
    return <Object?>[
      for (var i = 0; i < length; i++)
        ${functions.single}(value[i], state, '\$path[\$i]', depth + 1),
    ];
  } finally { state.leave(value); }''');
      case MapConversion(:final key, :final value):
        _code.writeln('''  state.enter(value, path, depth);
  try {
    final length = value.length;
    if (length < 0 || length > 0xffffffff) throw NapiTypeError('\$path.length: expected a Map length');
    if (length > (10000 - state.work) ~/ 2) throw NapiRangeError('\$path: structural work limit (10000) exceeded');
    final entries = <(${key.dartType}, ${value.dartType})>[];
    final iterator = value.entries.iterator;
    for (var i = 0; i < length; i++) {
      if (!iterator.moveNext()) throw NapiTypeError('\$path: Map length changed during iteration');
      final entry = iterator.current;
      entries.add((entry.key, entry.value));
    }
    if (iterator.moveNext()) throw NapiTypeError('\$path: Map length changed during iteration');
    return <Object?>[
      for (var i = 0; i < entries.length; i++) ...[
        ${functions[0]}(entries[i].\$1, state, '\$path[\$i].key', depth + 1),
        ${functions[1]}(entries[i].\$2, state, '\$path[\$i].value', depth + 1),
      ],
    ];
  } finally { state.leave(value); }''');
      case DictionaryConversion(:final value):
        _code.writeln('''  state.enter(value, path, depth);
  try {
    final length = value.length;
    if (length < 0 || length > 0xffffffff) throw NapiTypeError('\$path.length: expected a Dictionary length');
    if (length > 10000 - state.work) throw NapiRangeError('\$path: structural work limit (10000) exceeded');
    final entries = <(String, ${value.dartType})>[];
    final keys = <String>{};
    final iterator = value.entries.iterator;
    for (var i = 0; i < length; i++) {
      if (!iterator.moveNext()) throw NapiTypeError('\$path: Dictionary length changed during iteration');
      final entry = iterator.current;
      final key = entry.key;
      final child = entry.value;
      if (!keys.add(key)) throw NapiTypeError('\$path[\${jsonEncode(key)}]: duplicate Dictionary key');
      entries.add((key, child));
    }
    if (iterator.moveNext()) throw NapiTypeError('\$path: Dictionary length changed during iteration');
    return <Object?>[
      for (var i = 0; i < entries.length; i++) ...[
        entries[i].\$1,
        ${functions.single}(entries[i].\$2, state, '\$path[\${jsonEncode(entries[i].\$1)}]', depth + 1),
      ],
    ];
  } finally { state.leave(value); }''');
      case ValueClassConversion():
        _code.writeln('''  state.enter(value, path, depth);
  try {''');
        for (final (index, field) in conversion.fields.indexed) {
          final member =
              field.binding.callPath ?? field.binding.declaration.name;
          _code.writeln('    final raw$index = value.$member;');
        }
        _code.writeln('    return <Object?>[');
        for (final (index, field) in conversion.fields.indexed) {
          _code.writeln(
            '      ${functions[index]}(raw$index, state, path + ${_quote('.${field.name}')}, depth + 1),',
          );
        }
        _code.writeln('''    ];
  } finally { state.leave(value); }''');
      case RecordConversion():
        _code.writeln('''  state.enter(value, path, depth);
  try {
    return <Object?>[''');
        for (final (index, field) in conversion.fields.keys.indexed) {
          _code.writeln(
            '      ${functions[index]}(value.$field, state, path + ${_quote('.$field')}, depth + 1),',
          );
        }
        _code.writeln('''    ];
  } finally { state.leave(value); }''');
    }
    _code.writeln('}');
    return name;
  }

  String _writeSnapshot(ValueConversion conversion) {
    if (_snapshotWriters[conversion] case final previous?) return previous;
    final name = '_writeNativeSnapshot${_next++}';
    _snapshotWriters[conversion] = name;
    final functions = [
      for (final child in _children(conversion)) _writeSnapshot(child),
    ];
    _code.writeln(
      'int $name(Pointer<Void> env, Object? value, _NativeWriteState state, String path) {',
    );
    if (conversion.nullable) {
      _code.writeln('  if (value == null) return _api.nullResult(env);');
    }
    switch (conversion) {
      case ScalarConversion():
        final type = conversion.nullable
            ? conversion.dartType.substring(0, conversion.dartType.length - 1)
            : conversion.dartType;
        final context =
            conversion.kind == ScalarKind.integer && !conversion.usesBigInt
            ? ', path'
            : '';
        _code.writeln(
          '  return _api.${nativeScalarWriter(conversion)}(env, value as $type$context);',
        );
      case ReferenceConversion():
        _code.writeln(
          '  return _api.referenceResult(env, value!, ${conversion.classId}, path, state.pending);',
        );
      case ListConversion():
        _code.writeln('''  final items = value as List<Object?>;
  final result = _api.createContainer(env, true, items.length);
  for (var i = 0; i < items.length; i++) {
    final child = ${functions.single}(env, items[i], state, '\$path[\$i]');
    _api.defineOwnValue(env, result, '\$i', child);
  }
  return result;''');
      case MapConversion():
        _code.writeln('''  final items = value as List<Object?>;
  final result = _api.createMap(env);
  for (var i = 0; i < items.length ~/ 2; i++) {
    final keyPath = '\$path[\$i].key';
    final key = ${functions[0]}(env, items[2 * i], state, keyPath);
    final child = ${functions[1]}(env, items[2 * i + 1], state, '\$path[\$i].value');
    _api.checkedInsertMap(env, result, key, child, keyPath);
  }
  return result;''');
      case DictionaryConversion():
        _code.writeln('''  final items = value as List<Object?>;
  final result = _api.createDictionary(env);
  for (var i = 0; i < items.length ~/ 2; i++) {
    final key = items[2 * i] as String;
    final child = ${functions.single}(env, items[2 * i + 1], state, '\$path[\${jsonEncode(key)}]');
    _api.defineOwnValue(env, result, key, child);
  }
  return result;''');
      case ValueClassConversion() || RecordConversion():
        final fields = conversion is ValueClassConversion
            ? conversion.fields.map((f) => f.name).toList()
            : (conversion as RecordConversion).fields.keys.toList();
        _code.writeln('''  final items = value as List<Object?>;
  final result = _api.createContainer(env, false, 0);''');
        for (final (index, field) in fields.indexed) {
          _code.writeln(
            '  final child$index = ${functions[index]}(env, items[$index], state, path + ${_quote('.$field')});',
          );
          _code.writeln(
            '  _api.defineOwnValue(env, result, ${_quote(field)}, child$index);',
          );
        }
        _code.writeln('  return result;');
    }
    _code.writeln('}');
    return name;
  }

  List<ValueConversion> _children(ValueConversion value) => switch (value) {
    ListConversion(:final element) => [element],
    MapConversion(:final key, :final value) => [key, value],
    DictionaryConversion(:final value) => [value],
    RecordConversion() => value.fields.values.toList(),
    ValueClassConversion() => [
      for (final field in value.fields) field.conversion,
    ],
    ScalarConversion() || ReferenceConversion() => [],
  };

  // Only value-containing input roots use this path. Raw validation snapshots
  // into lists so neither value constructors nor Map equality/hashCode can run.
  String _normalize(ValueConversion conversion) {
    final previous = _normalizers[conversion];
    if (previous != null) return previous;
    if (conversion is ScalarConversion || conversion is ReferenceConversion) {
      return _normalizers[conversion] = _emit(conversion, false);
    }
    final name = '_normalizeNativeStructure${_next++}';
    _normalizers[conversion] = name;
    final functions = [
      for (final child in _children(conversion)) _normalize(child),
    ];
    _code.writeln(
      'Object? $name(Pointer<Void> env, Pointer<Void> value, _NativeReadState state, String path, int depth) {',
    );
    _code.writeln('  state.visit(path);');
    if (conversion.nullable) {
      _code.writeln('  if (_api.isNull(env, value)) return null;');
    }
    switch (conversion) {
      case ListConversion():
        _code.writeln(
          '''  final length = _api.inspectShape(env, value, true, const [], path, 10000 - state.work, depth, state.contains(env, value));
  state.active.add(value);
  try {
    final result = <Object?>[];
    for (var i = 0; i < length; i++) {
      final childPath = '\$path[\$i]';
      final raw = _api.readOwnValue(env, value, '\$i', childPath);
      result.add(${functions.single}(env, raw, state, childPath, depth + 1));
    }
    return result;
  } finally { state.active.removeLast(); }''',
        );
      case MapConversion():
        _code.writeln(
          '''  final (entries, length) = _api.snapshotMap(env, value, path, 10000 - state.work, depth, state.contains(env, value));
  state.active.add(value);
  try {
    final result = <Object?>[];
    for (var i = 0; i < length; i++) {
      final keyPath = '\$path[\$i].key';
      final rawKey = _api.readOwnValue(env, entries, '\${2 * i}', keyPath);
      result.add(${functions[0]}(env, rawKey, state, keyPath, depth + 1));
      final valuePath = '\$path[\$i].value';
      final rawValue = _api.readOwnValue(env, entries, '\${2 * i + 1}', valuePath);
      result.add(${functions[1]}(env, rawValue, state, valuePath, depth + 1));
    }
    return result;
  } finally { state.active.removeLast(); }''',
        );
      case DictionaryConversion():
        _code.writeln(
          '''  final (keys, length) = _api.dictionaryKeys(env, value, path, 10000 - state.work, depth, state.contains(env, value));
  state.active.add(value);
  try {
    final result = <Object?>[];
    for (var i = 0; i < length; i++) {
      final rawKey = _api.readOwnValue(env, keys, '\$i', path);
      final key = _api.string(env, rawKey, path);
      final childPath = '\$path[\${jsonEncode(key)}]';
      final raw = _api.readOwnValue(env, value, key, childPath);
      result.add(key);
      result.add(${functions.single}(env, raw, state, childPath, depth + 1));
    }
    return result;
  } finally { state.active.removeLast(); }''',
        );
      case RecordConversion():
        final fields = conversion.fields.keys.toList();
        _code.writeln(
          '  _api.inspectShape(env, value, false, const [${fields.map(_quote).join(', ')}], path, 10000 - state.work, depth, state.contains(env, value));',
        );
        _code.writeln(
          '  state.active.add(value);\n  try {\n    final result = <Object?>[];',
        );
        for (final (index, field) in fields.indexed) {
          final path = 'path + ${_quote('.$field')}';
          _code.writeln(
            '    final raw$index = _api.readOwnValue(env, value, ${_quote(field)}, $path);',
          );
          _code.writeln(
            '    result.add(${functions[index]}(env, raw$index, state, $path, depth + 1));',
          );
        }
        _code.writeln(
          '    return result;\n  } finally { state.active.removeLast(); }',
        );
      case ValueClassConversion():
        final fields = conversion.fields;
        _code.writeln(
          '  _api.inspectShape(env, value, false, const [${fields.map((f) => _quote(f.name)).join(', ')}], path, 10000 - state.work, depth, state.contains(env, value));',
        );
        _code.writeln(
          '  state.active.add(value);\n  try {\n    final result = <Object?>[];',
        );
        for (final (index, field) in fields.indexed) {
          final path = 'path + ${_quote('.${field.name}')}';
          final reader = field.optional
              ? 'readOptionalOwnValue'
              : 'readOwnValue';
          _code.writeln(
            '    final raw$index = _api.$reader(env, value, ${_quote(field.name)}, $path);',
          );
          if (field.optional) {
            _code.writeln(
              '''    final default$index = raw$index == nullptr || _api.isUndefined(env, raw$index);
    result.add(default$index);
    if (default$index) {
      state.visit($path);
      result.add(null);
    } else {
      result.add(${functions[index]}(env, raw$index, state, $path, depth + 1));
    }''',
            );
          } else {
            _code.writeln(
              '    result.add(false);\n    result.add(${functions[index]}(env, raw$index, state, $path, depth + 1));',
            );
          }
        }
        _code.writeln(
          '    return result;\n  } finally { state.active.removeLast(); }',
        );
      case ScalarConversion() || ReferenceConversion():
        throw StateError('Scalar/reference normalization uses strict readers');
    }
    _code.writeln('}');
    return name;
  }

  // This second, typed pass has no JS reflection or validation budget. Its
  // constructors and Map insertion run in the same postorder as the Wasm reader.
  String _materialize(ValueConversion conversion) {
    final previous = _materializers[conversion];
    if (previous != null) return previous;
    final name = '_materializeNativeStructure${_next++}';
    _materializers[conversion] = name;
    final functions = [
      for (final child in _children(conversion)) _materialize(child),
    ];
    _code.writeln('${conversion.dartType} $name(Object? value, String path) {');
    if (conversion is ScalarConversion || conversion is ReferenceConversion) {
      _code.writeln('  return value as ${conversion.dartType};\n}');
      return name;
    }
    if (conversion.nullable) _code.writeln('  if (value == null) return null;');
    _code.writeln('  final items = value as List<Object?>;');
    switch (conversion) {
      case ListConversion(:final element):
        _code.writeln('''  final result = <${element.dartType}>[];
  for (var i = 0; i < items.length; i++) {
    result.add(${functions.single}(items[i], '\$path[\$i]'));
  }
  return result;''');
      case MapConversion(:final key, :final value):
        _code.writeln(
          '''  final result = <${key.dartType}, ${value.dartType}>{};
  for (var i = 0; i < items.length; i += 2) {
    final keyPath = '\$path[\${i ~/ 2}].key';
    final key = ${functions[0]}(items[i], keyPath);
    final child = ${functions[1]}(items[i + 1], '\$path[\${i ~/ 2}].value');
    if (result.containsKey(key)) throw NapiTypeError('\$keyPath: duplicate converted Map key');
    result[key] = child;
  }
  return result;''',
        );
      case DictionaryConversion(:final value):
        _code.writeln('''  final result = <String, ${value.dartType}>{};
  for (var i = 0; i < items.length; i += 2) {
    final key = items[i] as String;
    result[key] = ${functions.single}(items[i + 1], '\$path[\${jsonEncode(key)}]');
  }
  return napi.Dictionary<${value.dartType}>(result);''');
      case RecordConversion():
        final fields = conversion.fields.keys.toList();
        for (final (index, field) in fields.indexed) {
          _code.writeln(
            '  final child$index = ${functions[index]}(items[$index], path + ${_quote('.$field')});',
          );
        }
        final entries = <String>[
          for (var i = 0; i < conversion.positional.length; i++) 'child$i',
          for (final (i, field) in conversion.named.keys.indexed)
            '$field: child${conversion.positional.length + i}',
        ];
        final trailing = entries.length == 1 && conversion.named.isEmpty
            ? ','
            : '';
        _code.writeln('  return (${entries.join(', ')}$trailing);');
      case ValueClassConversion():
        for (final (index, field) in conversion.fields.indexed) {
          final materialized =
              '${functions[index]}(items[${2 * index + 1}], path + ${_quote('.${field.name}')} )';
          final expression = field.optional
              ? '(items[${2 * index}] as bool) ? ${renderDartDefault(field.parameter!, field.conversion)} : $materialized'
              : materialized;
          _code.writeln(
            '  final ${field.conversion.dartType} child$index = $expression;',
          );
        }
        final arguments = [
          for (final (index, field) in conversion.fields.indexed)
            '${field.parameter!.kind == ParameterKind.requiredNamed || field.parameter!.kind == ParameterKind.optionalNamed ? '${field.parameter!.name}: ' : ''}child$index',
        ].join(', ');
        final constructor = conversion.constructor!;
        final suffix = constructor.declaration.name == 'new'
            ? ''
            : '.${constructor.declaration.name}';
        _code.writeln(
          '  return target.${conversion.classBinding.callPath}$suffix($arguments);',
        );
      case ScalarConversion() || ReferenceConversion():
        throw StateError('Scalar/reference materialization is a typed cast');
    }
    _code.writeln('}');
    return name;
  }
}

const nativeStructuralPrelude = r'''
final class _NativeReadState {
  int work = 0;
  final active = <Pointer<Void>>[];
  void visit(String path) {
    if (++work > 10000) throw NapiRangeError('$path: structural work limit (10000) exceeded');
  }
  bool contains(Pointer<Void> env, Pointer<Void> value) {
    for (final ancestor in active) {
      if (_api.strictEquals(env, value, ancestor)) return true;
    }
    return false;
  }
}
final class _NativeWriteState {
  int work = 0;
  final active = Set<Object>.identity();
  late final pending = <(Object, int)>[];
  void visit(String path) {
    if (++work > 10000) throw NapiRangeError('$path: structural work limit (10000) exceeded');
  }
  void enter(Object value, String path, int depth) {
    if (depth >= 64) throw NapiRangeError('$path: structural depth limit (64) exceeded');
    if (!active.add(value)) throw NapiTypeError('$path: cyclic structural value');
  }
  void leave(Object value) => active.remove(value);
}
''';
