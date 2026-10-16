import 'dart:convert';

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

  String read(ValueConversion conversion) => _emit(conversion, false);
  String write(ValueConversion conversion) => _emit(conversion, true);
  String get source => _code.toString();

  String _emit(ValueConversion conversion, bool output) {
    final name = '_${output ? 'write' : 'read'}NativeStructure${_next++}';
    final children = switch (conversion) {
      ListConversion(:final element) => [element],
      MapConversion(:final key, :final value) => [key, value],
      RecordConversion() => conversion.fields.values.toList(),
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
