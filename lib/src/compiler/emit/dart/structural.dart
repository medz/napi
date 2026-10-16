import '../../lowering/plan.dart';

/// The JavaScript boundary validates and snapshots inputs before these readers
/// run. Records cross this private ABI as arrays in declaration field order.
final class DartStructuralEmitter {
  final _code = StringBuffer();
  var _next = 0;

  String read(ValueConversion conversion) => _emit(conversion, false);
  String write(ValueConversion conversion) => _emit(conversion, true);
  String get source => _code.toString();

  String _emit(ValueConversion conversion, bool output) {
    final name = '_${output ? 'write' : 'read'}Structure${_next++}';
    final children = switch (conversion) {
      ListConversion(:final element) => [element],
      RecordConversion() => conversion.fields.values.toList(),
      ScalarConversion() || ReferenceConversion() => <ValueConversion>[],
    };
    final functions = [for (final child in children) _emit(child, output)];
    final type = conversion.dartType;
    _code.writeln(
      output
          ? 'JSAny? $name($type value, _StructureState state, String path, int depth) {'
          : '$type $name(JSAny? value) {',
    );
    if (output) _code.writeln('  state.visit(path);');
    if (conversion.nullable) _code.writeln('  if (value == null) return null;');
    switch (conversion) {
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
          _code.writeln(
            '  return <${element.dartType}>[for (final item in (value as JSArray<JSAny?>).toDart) ${functions.single}(item)];',
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
            entries.add('${functions[i]}(fields[$i])');
          }
          for (final (i, field) in conversion.named.keys.indexed) {
            final index = i + conversion.positional.length;
            entries.add('$field: ${functions[index]}(fields[$index])');
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
