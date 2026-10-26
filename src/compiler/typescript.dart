import 'dart:convert';

import 'exports.dart';

String typeScriptDeclarations(ExportModule exports) {
  final output = StringBuffer();
  for (final cls in exports.classes) {
    output.writeln('export declare class ${cls.name} {');
    var brand = '__napiBrand';
    final names = {
      ...cls.methods.map((m) => m.name),
      ...cls.properties.map((p) => p.name),
    };
    while (names.contains(brand)) {
      brand += '_';
    }
    output.writeln('  private readonly $brand: never;');
    final constructor = cls.constructor;
    output.writeln(
      constructor == null
          ? '  private constructor();'
          : '  constructor(${_parameters(constructor)});',
    );
    for (final function in cls.methods) {
      output.writeln(
        '  ${_member(function.name)}(${_parameters(function)}): ${_type(function.result)};',
      );
    }
    for (final function in cls.staticMethods) {
      output.writeln(
        '  static ${_member(function.name)}(${_parameters(function)}): ${_type(function.result)};',
      );
    }
    void property(ExportProperty property, {required bool static}) {
      final prefix = static ? 'static ' : '';
      output.writeln(
        '  ${prefix}get ${_member(property.name)}(): ${property.readType == null ? 'undefined' : _type(property.readType!)};',
      );
      if (property.writeType != null) {
        output.writeln(
          '  ${prefix}set ${_member(property.name)}(value: ${_type(property.writeType!)});',
        );
      }
    }

    for (final value in cls.properties) {
      property(value, static: false);
    }
    for (final value in cls.staticProperties) {
      property(value, static: true);
    }
    output.writeln('}');
  }
  for (final function in exports.functions) {
    output.writeln(
      'export declare function ${function.name}(${_parameters(function)}): ${_type(function.result)};',
    );
  }
  return output.toString();
}

String _parameters(ExportFunction function) {
  final required = function.positional
      .where((parameter) => parameter.required)
      .length;
  final tuples = <String>[];
  final options = function.named.isEmpty
      ? null
      : '{ ${function.named.map((parameter) => '${jsonEncode(parameter.name)}${parameter.required ? '' : '?'}: ${_type(parameter.type)};').join(' ')} }';
  for (var count = required; count <= function.positional.length; ++count) {
    final parameters = [
      for (var i = 0; i < count; ++i)
        '${_label(function.positional[i].name, i)}: ${_type(function.positional[i].type)}',
    ];
    if (options == null ||
        !function.named.any((parameter) => parameter.required)) {
      tuples.add('[${parameters.join(', ')}]');
    }
    if (options != null)
      tuples.add('[${[...parameters, 'options: $options'].join(', ')}]');
  }
  return '...args: ${tuples.join(' | ')}';
}

String _type(ExportType type) {
  final value = switch (type.kind) {
    ValueKind.boolean => 'boolean',
    ValueKind.integer || ValueKind.doubleValue || ValueKind.number => 'number',
    ValueKind.string => 'string',
    ValueKind.bigint => 'bigint',
    ValueKind.nullValue => 'null',
    ValueKind.voidValue => 'void',
    ValueKind.never => 'never',
    ValueKind.object => type.classExport!.name,
    ValueKind.list =>
      type.element!.nullable
          ? '(${_type(type.element!)})[]'
          : '${_type(type.element!)}[]',
    ValueKind.map => '{ [key: string]: ${_type(type.element!)} }',
    ValueKind.typedData =>
      'globalThis.${switch (type.typedDataKind!) {
        TypedDataKind.int8 => 'Int8Array',
        TypedDataKind.uint8 => 'Uint8Array',
        TypedDataKind.uint8Clamped => 'Uint8ClampedArray',
        TypedDataKind.int16 => 'Int16Array',
        TypedDataKind.uint16 => 'Uint16Array',
        TypedDataKind.int32 => 'Int32Array',
        TypedDataKind.uint32 => 'Uint32Array',
        TypedDataKind.int64 => 'BigInt64Array',
        TypedDataKind.uint64 => 'BigUint64Array',
        TypedDataKind.float32 => 'Float32Array',
        TypedDataKind.float64 => 'Float64Array',
      }}',
  };
  return type.nullable ? '$value | null' : value;
}

String _label(String name, int index) =>
    RegExp(r'^[a-zA-Z_$][a-zA-Z0-9_$]*$').hasMatch(name) ? name : 'arg$index';

String _member(String name) => name == 'constructor' ? '["constructor"]' : name;
