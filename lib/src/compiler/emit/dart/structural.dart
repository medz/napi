import '../../ir/model.dart';
import 'entrypoint.dart' show renderDartDefault;
import '../../lowering/plan.dart';

/// The JavaScript boundary validates and snapshots inputs before these readers
/// run. Records use declaration field order; Maps use flat key/value arrays.
final class DartStructuralEmitter {
  final _code = StringBuffer();
  var _next = 0;
  final _memo = <(ValueConversion, bool), String>{};

  String read(ValueConversion conversion) => _emit(conversion, false);
  String write(ValueConversion conversion) => _emit(conversion, true);
  String get source => _code.toString();

  String _emit(ValueConversion conversion, bool output) {
    final key = (conversion, output);
    if (_memo[key] case final name?) return name;
    final name = '_${output ? 'write' : 'read'}Structure${_next++}';
    _memo[key] = name;
    final children = switch (conversion) {
      ListConversion(:final element) => [element],
      MapConversion(:final key, :final value) => [key, value],
      DictionaryConversion(:final value) => [value],
      RecordConversion() => conversion.fields.values.toList(),
      ValueClassConversion() => [
        for (final field in conversion.fields) field.conversion,
      ],
      ScalarConversion() ||
      ReferenceConversion() ||
      OpaqueConversion() => <ValueConversion>[],
    };
    final functions = [for (final child in children) _emit(child, output)];
    final type = conversion.dartType;
    _code.writeln(
      output
          ? 'JSAny? $name($type value, _StructureState state, String path, int depth) {'
          : '$type $name(JSAny? value, String path) {',
    );
    if (output) _code.writeln('  state.visit(path);');
    if (conversion.nullable) _code.writeln('  if (value == null) return null;');
    switch (conversion) {
      case OpaqueConversion():
        throw StateError('Opaque structural conversion is not supported.');
      case ReferenceConversion():
        _code.writeln(
          output
              ? '  return WasmAnyRef.fromObject(value).externalize().toJS;'
              : '  return externRefForJSAny(value!)!.internalize().toObject() as ${conversion.dartType};',
        );
      case ScalarConversion():
        _code.writeln(
          '  return ${output ? _writeScalar(conversion) : _readScalar(conversion)};',
        );
      case ListConversion(:final element):
        if (output) {
          _code.writeln('''  state.enter(value, path, depth);
  try {
    final length = value.length;
    if (length < 0 || length > 0xffffffff) _structureError('\$path.length', 'expected an Array length', false);
    if (length > 10000 - state.work) _structureError(path, 'structural work limit (10000) exceeded', true);
    return <JSAny?>[
      for (var i = 0; i < length; i++)
        ${functions.single}(value[i], state, '\$path[\$i]', depth + 1),
    ].toJS;
  } finally { state.leave(value); }''');
        } else {
          _code.writeln('''  final items = (value as JSArray<JSAny?>).toDart;
  return <${element.dartType}>[
    for (var i = 0; i < items.length; i++)
      ${functions.single}(items[i], '\$path[\$i]'),
  ];''');
        }
      case MapConversion(:final key, :final value):
        if (output) {
          _code.writeln('''  state.enter(value, path, depth);
  try {
    final length = value.length;
    if (length < 0 || length > 0xffffffff) _structureError('\$path.length', 'expected a Map length', false);
    if (length > (10000 - state.work) ~/ 2) _structureError(path, 'structural work limit (10000) exceeded', true);
    final entries = <(${key.dartType}, ${value.dartType})>[];
    final iterator = value.entries.iterator;
    for (var i = 0; i < length; i++) {
      if (!iterator.moveNext()) _structureError(path, 'Map length changed during iteration', false);
      final entry = iterator.current;
      entries.add((entry.key, entry.value));
    }
    if (iterator.moveNext()) _structureError(path, 'Map length changed during iteration', false);
    return <JSAny?>[
      for (var i = 0; i < entries.length; i++) ...[
        ${functions[0]}(entries[i].\$1, state, '\$path[\$i].key', depth + 1),
        ${functions[1]}(entries[i].\$2, state, '\$path[\$i].value', depth + 1),
      ],
    ].toJS;
  } finally { state.leave(value); }''');
        } else {
          _code.writeln('''  final entries = (value as JSArray<JSAny?>).toDart;
  final result = <${key.dartType}, ${value.dartType}>{};
  for (var i = 0; i < entries.length ~/ 2; i++) {
    final keyPath = '\$path[\$i].key';
    final key = ${functions[0]}(entries[2 * i], keyPath);
    final child = ${functions[1]}(entries[2 * i + 1], '\$path[\$i].value');
    if (result.containsKey(key)) _structureError(keyPath, 'duplicate converted Map key', false);
    result[key] = child;
  }
  return result;''');
        }
      case DictionaryConversion(:final value):
        if (output) {
          _code.writeln('''  state.enter(value, path, depth);
  try {
    final length = value.length;
    if (length < 0 || length > 0xffffffff) _structureError('\$path.length', 'expected a Dictionary length', false);
    if (length > 10000 - state.work) _structureError(path, 'structural work limit (10000) exceeded', true);
    final entries = <(String, ${value.dartType})>[];
    final keys = <String>{};
    final iterator = value.entries.iterator;
    for (var i = 0; i < length; i++) {
      if (!iterator.moveNext()) _structureError(path, 'Dictionary length changed during iteration', false);
      final entry = iterator.current;
      final key = entry.key;
      final child = entry.value;
      if (!keys.add(key)) _structureError('\$path[\${jsonEncode(key)}]', 'duplicate Dictionary key', false);
      entries.add((key, child));
    }
    if (iterator.moveNext()) _structureError(path, 'Dictionary length changed during iteration', false);
    return <JSAny?>[
      for (var i = 0; i < entries.length; i++) ...[
        entries[i].\$1.toJS,
        ${functions.single}(entries[i].\$2, state, '\$path[\${jsonEncode(entries[i].\$1)}]', depth + 1),
      ],
    ].toJS;
  } finally { state.leave(value); }''');
        } else {
          _code.writeln('''  final entries = (value as JSArray<JSAny?>).toDart;
  final result = <String, ${value.dartType}>{};
  for (var i = 0; i < entries.length ~/ 2; i++) {
    final key = (entries[2 * i] as JSString).toDart;
    result[key] = ${functions.single}(entries[2 * i + 1], '\$path[\${jsonEncode(key)}]');
  }
  return napi.Dictionary<${value.dartType}>(result);''');
        }
      case ValueClassConversion():
        if (output) {
          _code.writeln('  state.enter(value, path, depth);\n  try {');
          for (final (index, field) in conversion.fields.indexed) {
            final member =
                field.binding.callPath ?? field.binding.declaration.name;
            _code.writeln('    final f$index = value.$member;');
          }
          _code.writeln('    return <JSAny?>[');
          for (final (index, field) in conversion.fields.indexed) {
            final path = field.name.replaceAll(r'$', r'\$');
            _code.writeln(
              "      ${functions[index]}(f$index, state, '\$path.$path', depth + 1),",
            );
          }
          _code.writeln('    ].toJS;\n  } finally { state.leave(value); }');
        } else {
          _code.writeln('  final fields = (value as JSArray<JSAny?>).toDart;');
          final arguments = <String>[];
          for (final (index, field) in conversion.fields.indexed) {
            final parameter = field.parameter!;
            final path = field.name.replaceAll(r'$', r'\$');
            final read =
                "${functions[index]}(fields[${2 * index + 1}], '\$path.$path')";
            final value = field.optional
                ? '(fields[${2 * index}] as JSBoolean).toDart ? ${renderDartDefault(parameter, field.conversion)} : $read'
                : read;
            _code.writeln(
              '  final ${field.conversion.dartType} a$index = $value;',
            );
            final named =
                parameter.kind == ParameterKind.requiredNamed ||
                parameter.kind == ParameterKind.optionalNamed;
            arguments.add('${named ? '${parameter.name}: ' : ''}a$index');
          }
          final constructor = conversion.constructor!;
          final suffix = constructor.declaration.name == 'new'
              ? ''
              : '.${constructor.declaration.name}';
          _code.writeln(
            '  return target.${conversion.classBinding.callPath}$suffix(${arguments.join(', ')});',
          );
        }
      case RecordConversion():
        if (output) {
          _code.writeln('  state.enter(value, path, depth);\n  try {');
          _code.writeln('    return <JSAny?>[');
          for (final (index, field) in conversion.fields.keys.indexed) {
            final pathField = field.replaceAll(r'$', r'\$');
            _code.writeln(
              "      ${functions[index]}(value.$field, state, '\$path.$pathField', depth + 1),",
            );
          }
          _code.writeln('    ].toJS;\n  } finally { state.leave(value); }');
        } else {
          _code.writeln('  final fields = (value as JSArray<JSAny?>).toDart;');
          final entries = <String>[];
          for (var i = 0; i < conversion.positional.length; i++) {
            final pathField = '.\$${i + 1}'.replaceAll(r'$', r'\$');
            entries.add("${functions[i]}(fields[$i], '\$path$pathField')");
          }
          for (final (i, field) in conversion.named.keys.indexed) {
            final index = i + conversion.positional.length;
            entries.add(
              "$field: ${functions[index]}(fields[$index], '\$path.$field')",
            );
          }
          final trailing = entries.length == 1 && conversion.named.isEmpty
              ? ','
              : '';
          _code.writeln('  return (${entries.join(', ')}$trailing);');
        }
    }
    _code.writeln('}');
    return name;
  }
}

String _readScalar(ScalarConversion conversion) {
  if (conversion.usesBigInt) {
    final parse = conversion.kind == ScalarKind.integer ? 'int' : 'BigInt';
    return '$parse.parse((_readBigInt(externRefForJSAny(value!)!).toJS as JSString).toDart)';
  }
  return switch (conversion.kind) {
    ScalarKind.boolean => '(value as JSBoolean).toDart',
    ScalarKind.string => '(value as JSString).toDart',
    ScalarKind.integer => '(value as JSNumber).toDartDouble.toInt()',
    ScalarKind.doubleValue => '(value as JSNumber).toDartDouble',
    ScalarKind.bigInteger => throw StateError('Handled above'),
  };
}

String _writeScalar(ScalarConversion conversion) =>
    conversion.usesBigInt ? 'value.toString().toJS' : 'value.toJS';

const dartStructuralPrelude = r'''
@pragma('wasm:import', 'napi.failStructure')
external WasmExternRef? _failStructure(WasmExternRef path, WasmExternRef message, WasmI32 range);

final class _StructureViolation implements Exception {
  final String path;
  final String message;
  final bool range;
  const _StructureViolation(this.path, this.message, this.range);
}

Never _structureError(String path, String message, bool range) =>
    throw _StructureViolation(path, message, range);

WasmExternRef? _reportStructureError(_StructureViolation error) =>
    _failStructure(externRefForJSAny(error.path.toJS)!, externRefForJSAny(error.message.toJS)!, WasmI32.fromInt(error.range ? 1 : 0));

// Each result owns its bounded state. No failed call leaves global state.
final class _StructureState {
  int work = 0;
  final active = Set<Object>.identity();
  void visit(String path) {
    if (++work > 10000) _structureError(path, 'structural work limit (10000) exceeded', true);
  }
  void enter(Object value, String path, int depth) {
    if (depth >= 64) _structureError(path, 'structural depth limit (64) exceeded', true);
    if (!active.add(value)) _structureError(path, 'cyclic structural value', false);
  }
  void leave(Object value) => active.remove(value);
}
''';
