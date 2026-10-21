import 'dart:convert';

import '../emit/dart/defaults.dart' show renderDartDefault;
import '../ir/model.dart' show DeclarationId, ParameterKind;
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

String nativeJsCollectionRead(
  JsCollectionConversion conversion,
  String env,
  String value,
  String path, {
  required NativeStructuralEmitter structures,
  String api = '_api',
}) {
  final hasResources = structures.hasResources;
  final method = conversion.isMap ? 'jsMap' : 'jsArray';
  final elements = [
    if (conversion.key case final key?) (key, conversion.inputKey!),
    (conversion.value, conversion.inputValue),
  ];
  final policies = elements
      .map((element) {
        final (c, input) = element;
        if (c is JsCollectionConversion) {
          return 'NativeJsElement<${c.dartType}>(\'handle\', nullable: ${c.nullable}, '
              'readHandle: (api, env, value, path) => ${nativeJsCollectionRead(input as JsCollectionConversion, 'env', 'value', 'path', structures: structures, api: 'api')}, '
              'writeHandle: (api, env, value, path) => api.jsCollectionResult(env, value${c.nullable ? '!' : ''}, ${_quote(c.signatureKey)}, path))';
        }
        if (c is ReferenceConversion) {
          final object = 'value${c.nullable ? '!' : ''}';
          String checkResource(String value) =>
              hasResources ? '_retainJsCollectionResource($value, path); ' : '';
          return 'NativeJsElement<${c.dartType}>(\'reference\', nullable: ${c.nullable}, '
              'readHandle: (api, env, value, path) { '
              'final object = api.ownerValue(env, value, path, ${c.classId}); '
              "if (object is! ${dartReferenceClassType(c.classBinding)}) throw NapiTypeError('\$path: expected ${c.classBinding.exportName}'); "
              '${checkResource('object')}return object; }, '
              'writeHandle: (api, env, value, path) { '
              '${checkResource(object)}return api.referenceResult(env, $object, ${c.classId}, path); })';
        }
        if (c is BinaryConversion) {
          return 'NativeJsElement<${c.dartType}>(\'binary\', nullable: ${c.nullable}, '
              'readHandle: (api, env, value, path) => api.binary(env, value, ${c.kind.index}, path) as ${c.dartType}, '
              'writeHandle: (api, env, value, path) => api.binaryResult(env, value${c.nullable ? '!' : ''}, ${c.kind.index}, path))';
        }
        if (c is SharedBytesConversion) {
          return 'NativeJsElement<${c.dartType}>(\'sharedBytes\', nullable: ${c.nullable}, '
              'readHandle: (api, env, value, path) => api.sharedBytes(env, value, path), '
              'writeHandle: (api, env, value, path) => api.sharedBytesResult(env, value${c.nullable ? '!' : ''}, path))';
        }
        if (c is ListConversion ||
            c is MapConversion ||
            c is DictionaryConversion ||
            c is RecordConversion ||
            c is ValueClassConversion) {
          final read = structures.read(input, forceNormalize: true);
          final write = structures.write(c, collectionElement: true);
          final tracksOpaque = conversionGraph([input])
              .any((leaf) => leaf is OpaqueConversion);
          final hasOwners = conversionGraph([c]).any(
            (leaf) => leaf is ReferenceConversion || leaf is CallbackConversion,
          );
          final state =
              '_NativeReadState('
              '${hasResources ? 'ResourceOperation.current' : ''}'
              '${tracksOpaque ? '${hasResources ? ', ' : ''}owned: owned' : ''})';
          final readHandle = tracksOpaque
              ? '''(api, env, value, path) {
  final owned = <NativeHostValue>[];
  try {
    final result = $read(env, value, $state, path, 0);
    owned.clear();
    return result;
  } catch (_) {
    for (final value in owned) { value.release(); }
    rethrow;
  }
}'''
              : '(api, env, value, path) => $read(env, value, $state, path, 0)';
          final writeHandle = hasOwners
              ? '''(api, env, value, path) {
  final state = _NativeWriteState();
  try {
    return $write(env, value, state, path, 0);
  } catch (_) {
    api.rollbackReferences(state.pending);
    rethrow;
  }
}'''
              : '(api, env, value, path) => $write(env, value, _NativeWriteState(), path, 0)';
          return 'NativeJsElement<${c.dartType}>(\'structure\', nullable: ${c.nullable}, '
              'readHandle: $readHandle, writeHandle: $writeHandle)';
        }
        return 'const NativeJsElement<${c.dartType}>(${_quote(c is OpaqueConversion ? 'opaque' : (c as ScalarConversion).kind.name)}, nullable: ${c.nullable}, bigint: ${c is ScalarConversion && c.bigint})';
      })
      .join(', ');
  return '$api.$method($env, $value, ${_quote(conversion.signatureKey)}, $path, $policies)';
}

/// Typed traversal owns only callback-scoped JS handles and ordinary Dart values.
final class NativeStructuralEmitter {
  final bool hasResources;
  final String Function(DeclarationId)? defaultDeclarationSource;
  final String Function(CallbackConversion)? callbackReader;
  final String Function(CallbackConversion)? functionExport;
  NativeStructuralEmitter({
    this.hasResources = false,
    this.defaultDeclarationSource,
    this.callbackReader,
    this.functionExport,
  });
  final _code = StringBuffer();
  var _next = 0;
  final _reads = Map<ValueConversion, String>.identity();
  final _writes = <(ValueConversion, bool), String>{};
  final _normalizers = Map<ValueConversion, String>.identity();
  final _materializers = Map<ValueConversion, String>.identity();
  final _outputSnapshots = <(ValueConversion, bool), String>{};
  final _snapshotWriters = Map<ValueConversion, String>.identity();

  String read(ValueConversion conversion, {bool forceNormalize = false}) {
    if (!forceNormalize &&
        !containsValueClass(conversion) &&
        !conversionGraph([conversion]).any(
          (value) =>
              value is BinaryConversion ||
              value is SharedBytesConversion ||
              value is JsCollectionConversion ||
              value is OpaqueConversion,
        )) {
      return _read(conversion);
    }
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

  String write(ValueConversion conversion, {bool collectionElement = false}) {
    final key = (conversion, collectionElement);
    if (_writes[key] case final previous?) return previous;
    final snapshot = _snapshotOutput(
      conversion,
      collectionElement: collectionElement,
    );
    final hostWrite = _writeSnapshot(conversion);
    final name = '_writeNativeOutput${_next++}';
    _writes[key] = name;
    _code.writeln(
      '''int $name(Pointer<Void> env, ${conversion.dartType} value, _NativeWriteState state, String path, int depth) {
  final snapshot = $snapshot(value, _NativeWriteState(), path, depth);
  return $hostWrite(env, snapshot, state, path);
}''',
    );
    return name;
  }

  // Callback arguments share one Dart serialization phase before host checks.
  String snapshotOutput(ValueConversion conversion) =>
      _snapshotOutput(conversion);
  String writeSnapshot(ValueConversion conversion) =>
      _writeSnapshot(conversion);

  String get source => _code.toString();

  String _read(ValueConversion conversion) {
    final previous = _reads[conversion];
    if (previous != null) return previous;
    final name = '_readNativeStructure${_next++}';
    _reads[conversion] = name;
    final functions = [for (final child in _children(conversion)) _read(child)];
    final collection = conversion is JsCollectionConversion
        ? nativeJsCollectionRead(
            conversion,
            'env',
            'value',
            'path',
            structures: this,
          )
        : null;
    _code.writeln(
      '${conversion.dartType} $name(Pointer<Void> env, Pointer<Void> value, _NativeReadState state, String path, int depth) {',
    );
    _code.writeln('  state.visit(path);');
    if (conversion.nullable && conversion is! OpaqueConversion) {
      _code.writeln('  if (_api.isNull(env, value)) return null;');
    }
    switch (conversion) {
      case AbortSignalConversion():
        throw StateError(
          'Signal and callback structural leaves are unsupported',
        );
      case CallbackConversion():
        _code.writeln(
          '  return ${callbackReader!(conversion)}(env, value, path);',
        );
      case JsCollectionConversion():
        // The adapter owns its source, including cache hits and constructor
        // escapes. It must not join the opaque input rollback list.
        _code.writeln('  return $collection;');
      case OpaqueConversion():
        _code.writeln(
          '  final owned = _api.ownHostValue(env, value);\n  state.owned?.add(owned);\n  return owned;',
        );
      case SharedBytesConversion():
        _code.writeln('  return _api.sharedBytes(env, value, path);');
      case BinaryConversion():
        _code.writeln(
          '  return _api.binary(env, value, ${conversion.kind.index}, path) as ${conversion.dartType};',
        );
      case ReferenceConversion():
        _code.writeln(
          '  final object = _api.ownerValue(env, value, path, ${conversion.classId});',
        );
        _code.writeln(
          "  if (object is! ${dartReferenceClassType(conversion.classBinding)}) throw NapiTypeError('\$path: expected ${conversion.classBinding.exportName}');",
        );
        if (hasResources) {
          _code.writeln('''  final control = _resourceControl(object);
  if (control != null) {
    final operation = state.operation;
    if (operation == null) throw NapiTypeError('\$path: resource access requires an active bound call');
    operation.retain(control);
  }''');
        }
        _code.writeln('  return object;');
      case ScalarConversion():
        _code.writeln(
          '  return _api.${nativeScalarReader(conversion)}(env, value, path${conversion.nullable ? ', nullable: true' : ''});',
        );
      case ListConversion(:final element):
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
      case MapConversion(:final key, :final value):
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
      case DictionaryConversion(:final value):
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
      case ValueClassConversion():
        throw StateError('Value inputs require normalization');
      case RecordConversion():
        final fields = conversion.fields.keys.toList();
        _code.writeln(
          '''  _api.inspectShape(env, value, false, const [${fields.map(_quote).join(', ')}], path, 10000 - state.work, depth, state.contains(env, value));
  state.active.add(value);
  try {''',
        );
        for (final (index, field) in fields.indexed) {
          final path = 'path + ${_quote('.$field')}';
          _code.writeln(
            '    final raw$index = _api.readOwnValue(env, value, ${_quote(field)}, $path);',
          );
          _code.writeln(
            '    final child$index = ${functions[index]}(env, raw$index, state, $path, depth + 1);',
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
        _code.writeln('    return (${entries.join(', ')}$trailing);');
        _code.writeln('  } finally { state.active.removeLast(); }');
    }
    _code.writeln('}');
    return name;
  }

  // Match the Wasm Dart serialization phase before any host scalar checks,
  // reference identity claims or JavaScript Map insertion. Snapshots contain only
  // plain Dart lists and typed leaves; no business getter runs in the host pass.
  String _snapshotOutput(
    ValueConversion conversion, {
    bool collectionElement = false,
  }) {
    final retainResources =
        collectionElement &&
        hasResources &&
        conversionGraph([conversion])
            .any((value) => value is ReferenceConversion);
    final key = (conversion, collectionElement);
    if (_outputSnapshots[key] case final previous?) return previous;
    final name = '_snapshotNativeOutput${_next++}';
    _outputSnapshots[key] = name;
    final functions = [
      for (final child in _children(conversion))
        _snapshotOutput(child, collectionElement: collectionElement),
    ];
    _code.writeln(
      'Object? $name(${conversion.dartType} value, _NativeWriteState state, String path, int depth) {',
    );
    _code.writeln('  state.visit(path);');
    if (conversion.nullable) _code.writeln('  if (value == null) return null;');
    switch (conversion) {
      case AbortSignalConversion():
        throw StateError(
          'Signal and callback structural leaves are unsupported',
        );
      case CallbackConversion():
        _code.writeln('  return value;');
      case BinaryConversion():
        final bytes = conversion.kind == BinaryKind.uint8List
            ? 'value'
            : 'value.asUint8List()';
        _code.writeln(
          "  final bytes = $bytes;\n"
          "  if (bytes.lengthInBytes > ${BinaryConversion.maxByteLength}) throw NapiRangeError('\$path: binary byte length exceeds ${BinaryConversion.maxByteLength}');\n"
          '  final snapshot = typed_data.Uint8List.fromList(bytes);\n'
          '  return snapshot${conversion.kind == BinaryKind.byteBuffer ? '.buffer' : ''};',
        );
      case ReferenceConversion():
        if (retainResources) {
          _code.writeln('  _retainJsCollectionResource(value, path);');
        }
        _code.writeln('  return value;');
      case OpaqueConversion() ||
          ScalarConversion() ||
          JsCollectionConversion() ||
          SharedBytesConversion():
        _code.writeln('  return value;');
      case ListConversion(:final element):
        _code.writeln(
          '''  state.enter(value, path, depth);
  try {
    final length = value.length;
    if (length < 0 || length > 0xffffffff) throw NapiTypeError('\$path.length: expected an Array length');
    if (length > 10000 - state.work) throw NapiRangeError('\$path: structural work limit (10000) exceeded');''',
        );
        if (element is ScalarConversion ||
            (element is ReferenceConversion && !retainResources)) {
          _code.writeln(
            '''    final result = List<Object?>.filled(length, null);
    for (var i = 0; i < length; i++) result[i] = value[i];
    state.work += length;
    return result;''',
          );
        } else {
          _code.writeln('''    return <Object?>[
      for (var i = 0; i < length; i++)
        ${functions.single}(value[i], state, '\$path[\$i]', depth + 1),
    ];''');
        }
        _code.writeln('  } finally { state.leave(value); }');
      case MapConversion(:final key, :final value):
        _code.writeln('''  state.enter(value, path, depth);
  try {
    final length = value.length;
    if (length < 0 || length > 0xffffffff) throw NapiTypeError('\$path.length: expected a Map length');
    if (length > (10000 - state.work) ~/ 2) throw NapiRangeError('\$path: structural work limit (10000) exceeded');
    final entries = List<Object?>.filled(length * 2, null);
    final iterator = value.entries.iterator;
    for (var i = 0; i < length; i++) {
      if (!iterator.moveNext()) throw NapiTypeError('\$path: Map length changed during iteration');
      final entry = iterator.current;
      final ${key.dartType} key = entry.key;''');
        if (retainResources) {
          _code.writeln(
            '''      entries[2 * i] = ${functions[0]}(key, state, '\$path[\$i].key', depth + 1);
      final ${value.dartType} child = entry.value;
      entries[2 * i + 1] = ${functions[1]}(child, state, '\$path[\$i].value', depth + 1);''',
          );
        } else {
          _code.writeln('''      final ${value.dartType} child = entry.value;
      entries[2 * i] = key;
      entries[2 * i + 1] = child;''');
        }
        _code.writeln(
          '''
    }
    if (iterator.moveNext()) throw NapiTypeError('\$path: Map length changed during iteration');''',
        );
        if (!retainResources &&
            (key is ScalarConversion || key is ReferenceConversion) &&
            (value is ScalarConversion || value is ReferenceConversion)) {
          _code.writeln('    state.work += length * 2;');
        } else if (!retainResources) {
          _code.writeln('''    for (var i = 0; i < length; i++) {
      entries[2 * i] = ${functions[0]}(entries[2 * i] as ${key.dartType}, state, '\$path[\$i].key', depth + 1);
      entries[2 * i + 1] = ${functions[1]}(entries[2 * i + 1] as ${value.dartType}, state, '\$path[\$i].value', depth + 1);
    }''');
        }
        _code.writeln(
          '    return entries;\n  } finally { state.leave(value); }',
        );
      case DictionaryConversion(:final value):
        _code.writeln('''  state.enter(value, path, depth);
  try {
    final length = value.length;
    if (length < 0 || length > 0xffffffff) throw NapiTypeError('\$path.length: expected a Dictionary length');
    if (length > 10000 - state.work) throw NapiRangeError('\$path: structural work limit (10000) exceeded');
    final entries = List<Object?>.filled(length * 2, null);
    final keys = <String>{};
    final iterator = value.entries.iterator;
    for (var i = 0; i < length; i++) {
      if (!iterator.moveNext()) throw NapiTypeError('\$path: Dictionary length changed during iteration');
      final entry = iterator.current;
      final String key = entry.key;''');
        if (!retainResources) {
          _code.writeln('      final ${value.dartType} child = entry.value;');
        }
        _code.writeln('''
      if (!keys.add(key)) throw NapiTypeError('\$path[\${jsonEncode(key)}]: duplicate Dictionary key');
      entries[2 * i] = key;''');
        if (retainResources) {
          _code.writeln(
            '''      final ${value.dartType} child = entry.value;
      entries[2 * i + 1] = ${functions.single}(child, state, '\$path[\${jsonEncode(key)}]', depth + 1);''',
          );
        } else {
          _code.writeln('      entries[2 * i + 1] = child;');
        }
        _code.writeln(
          '''
    }
    if (iterator.moveNext()) throw NapiTypeError('\$path: Dictionary length changed during iteration');''',
        );
        if (!retainResources &&
            (value is ScalarConversion || value is ReferenceConversion)) {
          _code.writeln('    state.work += length;');
        } else if (!retainResources) {
          _code.writeln('''    for (var i = 0; i < length; i++) {
      final key = entries[2 * i] as String;
      entries[2 * i + 1] = ${functions.single}(entries[2 * i + 1] as ${value.dartType}, state, '\$path[\${jsonEncode(key)}]', depth + 1);
    }''');
        }
        _code.writeln(
          '    return entries;\n  } finally { state.leave(value); }',
        );
      case ValueClassConversion():
        _code.writeln('''  state.enter(value, path, depth);
  try {''');
        if (collectionElement) {
          _code.writeln(
            '    final result = List<Object?>.filled(${conversion.fields.length}, null);',
          );
          for (final (index, field) in conversion.fields.indexed) {
            final binding = field.binding!;
            final member = binding.callPath ?? binding.declaration.name;
            _code.writeln(
              '    result[$index] = ${functions[index]}(value.$member, state, path + ${_quote('.${field.name}')}, depth + 1);',
            );
          }
          _code.writeln('    return result;');
        } else {
          for (final (index, field) in conversion.fields.indexed) {
            final binding = field.binding!;
            final member = binding.callPath ?? binding.declaration.name;
            _code.writeln('    final raw$index = value.$member;');
          }
          _code.writeln('    return <Object?>[');
          for (final (index, field) in conversion.fields.indexed) {
            _code.writeln(
              '      ${functions[index]}(raw$index, state, path + ${_quote('.${field.name}')}, depth + 1),',
            );
          }
          _code.writeln('    ];');
        }
        _code.writeln('  } finally { state.leave(value); }');
      case RecordConversion():
        _code.writeln('''  state.enter(value, path, depth);
  try {
    final result = List<Object?>.filled(${conversion.fields.length}, null);''');
        for (final (index, field) in conversion.fields.entries.indexed) {
          final child = field.value;
          if (child is ScalarConversion ||
              (child is ReferenceConversion && !retainResources)) {
            _code.writeln('''    final raw$index = value.${field.key};
    if (++state.work > 10000) throw NapiRangeError('\$path.${field.key.replaceAll(r'$', r'\$')}: structural work limit (10000) exceeded');
    result[$index] = raw$index;''');
          } else {
            _code.writeln(
              '    result[$index] = ${functions[index]}(value.${field.key}, state, path + ${_quote('.${field.key}')}, depth + 1);',
            );
          }
        }
        _code.writeln(
          '    return result;\n  } finally { state.leave(value); }',
        );
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
      case AbortSignalConversion():
        throw StateError(
          'Signal and callback structural leaves are unsupported',
        );
      case CallbackConversion():
        _code.writeln(
          '  return _api.functionResult(env, value as Function, ${_quote(conversion.signatureKey)}, ${_quote(conversion.wireSignatureKey)}, ${_quote(functionExport!(conversion))}, state.pending);',
        );
      case JsCollectionConversion():
        _code.writeln(
          '  return _api.jsCollectionResult(env, value!, ${_quote(conversion.signatureKey)}, path);',
        );
      case OpaqueConversion():
        _code.writeln(
          '  return _api.hostValue(env, value as NativeHostValue).address;',
        );
      case SharedBytesConversion():
        _code.writeln(
          '  return _api.sharedBytesResult(env, value as napi.SharedBytes, path);',
        );
      case BinaryConversion():
        _code.writeln(
          '  return _api.binaryResult(env, value!, ${conversion.kind.index}, path);',
        );
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
        if (hasResources) {
          _code.writeln('''  if (state.retainResources) {
    final control = _resourceControl(value!);
    if (control != null) {
      final operation = state.operation;
      if (operation == null) throw NapiTypeError('\$path: resource access requires an active bound call');
      operation.retain(control);
    }
  }''');
        }
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
    ScalarConversion() ||
    ReferenceConversion() ||
    BinaryConversion() ||
    SharedBytesConversion() ||
    JsCollectionConversion() ||
    CallbackConversion() ||
    OpaqueConversion() => [],
    AbortSignalConversion() => throw StateError(
      'Signal and callback structural leaves are unsupported',
    ),
  };

  // Value-class and binary input roots snapshot into lists before constructors
  // or Map equality/hashCode can run user code and mutate later binary leaves.
  String _normalize(ValueConversion conversion) {
    final previous = _normalizers[conversion];
    if (previous != null) return previous;
    if (conversion is ScalarConversion ||
        conversion is ReferenceConversion ||
        conversion is BinaryConversion ||
        conversion is SharedBytesConversion ||
        conversion is JsCollectionConversion ||
        conversion is CallbackConversion ||
        conversion is OpaqueConversion) {
      return _normalizers[conversion] = _read(conversion);
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
      case AbortSignalConversion():
      case CallbackConversion():
      case JsCollectionConversion():
      case OpaqueConversion():
        throw StateError('Signal, callback or unreachable leaf conversion');
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
        if (conversion.constructor == null) {
          _code.writeln(
            "  throw NapiTypeError('\$path: value class has no input constructor');",
          );
          break;
        }
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
      case ScalarConversion() ||
          ReferenceConversion() ||
          BinaryConversion() ||
          SharedBytesConversion():
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
    if (conversion is ScalarConversion ||
        conversion is ReferenceConversion ||
        conversion is BinaryConversion ||
        conversion is SharedBytesConversion ||
        conversion is JsCollectionConversion ||
        conversion is CallbackConversion ||
        conversion is OpaqueConversion) {
      _code.writeln('  return value as ${conversion.dartType};\n}');
      return name;
    }
    if (conversion.nullable) _code.writeln('  if (value == null) return null;');
    _code.writeln('  final items = value as List<Object?>;');
    switch (conversion) {
      case AbortSignalConversion():
      case CallbackConversion():
      case JsCollectionConversion():
      case OpaqueConversion():
        throw StateError('Signal, callback or unreachable leaf conversion');
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
        if (conversion.constructor == null) {
          _code.writeln(
            "  throw NapiTypeError('\$path: value class has no input constructor');",
          );
          break;
        }
        for (final (index, field) in conversion.fields.indexed) {
          final materialized =
              '${functions[index]}(items[${2 * index + 1}], path + ${_quote('.${field.name}')} )';
          final expression = field.optional
              ? '(items[${2 * index}] as bool) ? ${renderDartDefault(field.parameter!, field.conversion, declarationSource: defaultDeclarationSource)} : $materialized'
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
      case ScalarConversion() ||
          ReferenceConversion() ||
          BinaryConversion() ||
          SharedBytesConversion():
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
