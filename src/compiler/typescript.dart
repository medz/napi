import 'dart:convert';

import 'exports.dart';

String typeScriptDeclarations(ExportModule exports) {
  final output = StringBuffer();
  for (final enumeration in exports.enums) {
    output.writeln('export declare const ${enumeration.name}: {');
    for (final value in enumeration.cases) {
      output.writeln('  readonly ${jsonEncode(value.name)}: ${value.index};');
    }
    output.writeln('};');
    output.writeln(
      'export type ${enumeration.name} = typeof ${enumeration.name}[keyof typeof ${enumeration.name}];',
    );
  }
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
          : '  constructor(${_parameters(constructor.signature)});',
    );
    for (final function in cls.methods) {
      output.writeln(
        '  ${_member(function.name)}(${_parameters(function.signature)}): ${_type(function.signature.result)};',
      );
    }
    for (final function in cls.staticMethods) {
      output.writeln(
        '  static ${_member(function.name)}(${_parameters(function.signature)}): ${_type(function.signature.result)};',
      );
    }
    void property(ExportProperty property, {required bool static}) {
      final prefix = static ? 'static ' : '';
      output.writeln(
        '  ${prefix}get ${_member(property.name)}(): ${property.readType == null ? 'undefined' : _type(property.readType!)};',
      );
      if (property.writeType != null) {
        output.writeln(
          '  ${prefix}set ${_member(property.name)}(value: ${_type(property.writeType!, output: false)});',
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
      'export declare function ${function.name}(${_parameters(function.signature)}): ${_type(function.signature.result)};',
    );
  }
  return output.toString();
}

String _parameters(ExportSignature function, {bool output = true}) {
  final required = function.positional
      .where((parameter) => parameter.required)
      .length;
  final tuples = <String>[];
  final options = function.named.isEmpty
      ? null
      : '{ ${function.named.map((parameter) => '${jsonEncode(parameter.name)}${parameter.required ? '' : '?'}: ${_type(parameter.type, output: !output)};').join(' ')} }';
  for (var count = required; count <= function.positional.length; ++count) {
    final parameters = [
      for (var i = 0; i < count; ++i)
        '${_label(function.positional[i].name, i)}: ${_type(function.positional[i].type, output: !output)}',
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

String _type(ExportType type, {bool output = true}) {
  final value = switch (type.kind) {
    ValueKind.boolean => 'boolean',
    ValueKind.integer || ValueKind.doubleValue || ValueKind.number => 'number',
    ValueKind.string => 'string',
    ValueKind.bigint => 'bigint',
    ValueKind.nullValue => 'null',
    ValueKind.voidValue => 'void',
    ValueKind.never => 'never',
    ValueKind.object => type.classExport!.name,
    ValueKind.enumeration => type.enumExport!.name,
    ValueKind.function =>
      '((${_parameters(type.signature!, output: output)}) => ${_type(type.signature!.result, output: output)})',
    ValueKind.future =>
      output
          ? 'globalThis.Promise<globalThis.Awaited<${_type(type.element!, output: output)}>>'
          : 'globalThis.Promise<${_type(type.element!, output: output)}>',
    ValueKind.record => _record(type, output: output),
    ValueKind.stream =>
      'globalThis.${output ? 'AsyncIterableIterator' : 'AsyncIterable'}<${_type(type.element!, output: output)}>',
    ValueKind.list =>
      type.element!.nullable
          ? '(${_type(type.element!, output: output)})[]'
          : '${_type(type.element!, output: output)}[]',
    ValueKind.map =>
      '{ [key: string]: ${_type(type.element!, output: output)} }',
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

String _record(ExportType type, {required bool output}) {
  final fields = type.recordFields!;
  if (fields.named.isEmpty) {
    return '[${fields.positional.map((field) => _type(field, output: output)).join(', ')}]';
  }
  final properties = [
    for (var i = 0; i < fields.positional.length; ++i)
      '${jsonEncode('\$${i + 1}')}: ${_type(fields.positional[i], output: output)};',
    for (final entry in fields.named.entries)
      '${jsonEncode(entry.key)}: ${_type(entry.value, output: output)};',
  ];
  return '{ ${properties.join(' ')} }';
}

String _label(String name, int index) =>
    RegExp(r'^[a-zA-Z_$][a-zA-Z0-9_$]*$').hasMatch(name) ? name : 'arg$index';

String _member(String name) => name == 'constructor' ? '["constructor"]' : name;
