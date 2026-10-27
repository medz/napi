import 'dart:convert';

import 'package:kernel/ast.dart' show TypeParameter;

import 'exports.dart';

String typeScriptDeclarations(ExportModule exports, {bool esm = false}) =>
    _Writer(exports, esm: esm).write();

final class _Writer {
  _Writer(this.exports, {required this.esm})
    : _names = {
        ...exports.classes.map((value) => value.name),
        ...exports.functions.map((value) => value.name),
        ...exports.enums.map((value) => value.name),
        ...exports.constants.map((value) => value.name),
        ...exports.properties.map((value) => value.name),
      } {
    for (final cls in exports.classes) {
      _registerParameters(cls.typeParameters);
      for (final function in [
        if (cls.constructor != null) cls.constructor!,
        ...cls.methods,
        ...cls.staticMethods,
      ]) {
        _registerParameters(
          function.signature.typeParameters,
          enclosing: cls.typeParameters,
        );
      }
    }
    for (final function in exports.functions) {
      _registerParameters(function.signature.typeParameters);
    }
  }
  final ExportModule exports;
  final bool esm;
  final Set<String> _names;
  final _parameterNames = <TypeParameter, String>{};
  final _inputs = <ExportClass, String>{};
  final _inputQueue = <ExportClass>[];

  String _unique(String name) {
    while (_names.contains(name) || _parameterNames.containsValue(name)) {
      name += '_';
    }
    _names.add(name);
    return name;
  }

  void _registerParameters(
    List<ExportTypeParameter> parameters, {
    List<ExportTypeParameter> enclosing = const [],
  }) {
    final used = {
      for (final parameter in enclosing) _parameterNames[parameter.target]!,
    };
    for (final parameter in parameters) {
      final existing = _parameterNames[parameter.target];
      if (existing != null) {
        used.add(existing);
        continue;
      }
      var name = RegExp(r'^[a-zA-Z_$][a-zA-Z0-9_$]*$').hasMatch(parameter.name)
          ? parameter.name
          : 'T';
      while (_reservedParameterNames.contains(name) ||
          _names.contains(name) ||
          used.contains(name)) {
        name += '_';
      }
      _parameterNames[parameter.target] = name;
      used.add(name);
    }
  }

  String _generics(
    List<ExportTypeParameter> parameters, {
    bool defaults = true,
  }) {
    if (parameters.isEmpty) return '';
    final pending = {for (final parameter in parameters) parameter.target};
    final declarations = <String>[];
    for (final parameter in parameters) {
      if (!defaults) {
        declarations.add(_parameterDeclaration(parameter));
        continue;
      }
      final bound = parameter.bound;
      final defaultType =
          bound.kind == ValueKind.typeParameter ||
              parameter.defaultType.kind == ValueKind.dynamicValue &&
                  !(bound.kind == ValueKind.opaque && bound.nullable) &&
                  bound.kind != ValueKind.dynamicValue
          ? bound
          : parameter.defaultType;
      if (defaultType.kind == ValueKind.typeParameter &&
          pending.contains(defaultType.parameter!.target)) {
        throw FormatException(
          '@NAPI: TypeScript generic defaults cannot reference a later '
          'type parameter: ${parameter.name}.',
        );
      }
      declarations.add(_parameterDeclaration(parameter, defaultType));
      pending.remove(parameter.target);
    }
    return '<${declarations.join(', ')}>';
  }

  String _parameterDeclaration(
    ExportTypeParameter parameter, [
    ExportType? defaultType,
  ]) {
    final name = _parameterNames[parameter.target]!;
    final bound = parameter.bound;
    final constraint =
        bound.kind == ValueKind.dynamicValue ||
            bound.kind == ValueKind.opaque && bound.nullable
        ? ''
        : ' extends ${_type(bound)}';
    if (defaultType == null) return '$name$constraint';
    final value = defaultType.kind == ValueKind.dynamicValue
        ? 'unknown'
        : _type(defaultType);
    return '$name$constraint = $value';
  }

  String _parameterArguments(List<ExportTypeParameter> parameters) =>
      parameters.isEmpty
      ? ''
      : '<${parameters.map((parameter) => _parameterNames[parameter.target]!).join(', ')}>';

  String _input(ExportClass cls) {
    if (cls.constructor == null) {
      throw FormatException(
        '@NAPI.object ${cls.name}: has no annotated input constructor.',
      );
    }
    return _inputs.putIfAbsent(cls, () {
      final name = _unique('_NapiObjectInput${_inputs.length}');
      _inputQueue.add(cls);
      return name;
    });
  }

  String write() {
    final output = StringBuffer();
    final commonJsObject = !esm && exports.properties.isNotEmpty;
    final prefix = commonJsObject ? '' : 'export ';
    for (final enumeration in exports.enums) {
      output.writeln('${prefix}declare const ${enumeration.name}: {');
      for (final value in enumeration.cases) {
        output.writeln('  readonly ${jsonEncode(value.name)}: ${value.index};');
      }
      output.writeln('};');
      output.writeln(
        '${prefix}type ${enumeration.name} = typeof ${enumeration.name}[keyof typeof ${enumeration.name}];',
      );
    }
    for (final cls in exports.classes) {
      if (cls.isObject) {
        output.writeln(
          '${prefix}interface ${cls.name}${_generics(cls.typeParameters)} {',
        );
        for (final property in cls.properties) {
          output.writeln(
            '  ${jsonEncode(property.name)}: ${_type(property.readType!)};',
          );
        }
        output.writeln('}');
        continue;
      }
      output.writeln(
        '${prefix}declare class ${cls.name}${_generics(cls.typeParameters)} {',
      );
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
          '  ${_member(function.name)}${_generics(function.signature.typeParameters, defaults: false)}(${_parameters(function.signature)}): ${_type(function.signature.result)};',
        );
      }
      for (final function in cls.staticMethods) {
        output.writeln(
          '  static ${_member(function.name)}${_generics(function.signature.typeParameters, defaults: false)}(${_parameters(function.signature)}): ${_type(function.signature.result)};',
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
        '${prefix}declare function ${function.name}${_generics(function.signature.typeParameters, defaults: false)}(${_parameters(function.signature)}): ${_type(function.signature.result)};',
      );
    }
    for (final value in exports.constants) {
      output.writeln(
        '${prefix}declare const ${value.name}: ${_type(value.type)};',
      );
    }
    if (esm || commonJsObject) _binding(output);
    for (var i = 0; i < _inputQueue.length; ++i) {
      final cls = _inputQueue[i];
      final signature = cls.constructor!.signature;
      output.writeln(
        'type ${_inputs[cls]}${_generics(cls.typeParameters)} = object & {',
      );
      for (final parameter in [...signature.positional, ...signature.named]) {
        output.writeln(
          '  ${jsonEncode(parameter.name)}${parameter.required ? '' : '?'}: ${_type(parameter.type, output: false)};',
        );
      }
      output.writeln('}');
    }
    if (!commonJsObject) output.writeln('export {};');
    return output.toString();
  }

  void _binding(StringBuffer output) {
    final binding = _unique('_NapiBinding');
    output.writeln('declare const $binding: {');
    for (final name in [
      ...exports.classes
          .where((value) => !value.isObject)
          .map((value) => value.name),
      ...exports.functions.map((value) => value.name),
      ...exports.enums.map((value) => value.name),
      ...exports.constants.map((value) => value.name),
    ]) {
      output.writeln('  readonly ${jsonEncode(name)}: typeof $name;');
    }
    for (final property in exports.properties) {
      output.writeln(
        '  get ${_member(property.name)}(): ${property.readType == null ? 'undefined' : _type(property.readType!)};',
      );
      if (property.writeType != null) {
        output.writeln(
          '  set ${_member(property.name)}(value: ${_type(property.writeType!, output: false)});',
        );
      }
    }
    output.writeln('};');
    final aliases =
        <String, ({String alias, List<ExportTypeParameter> parameters})>{};
    void alias(String name, List<ExportTypeParameter> parameters) {
      final alias = _unique('_NapiType${aliases.length}');
      aliases[name] = (alias: alias, parameters: parameters);
      output.writeln(
        'type $alias${_generics(parameters)} = $name${_parameterArguments(parameters)};',
      );
    }

    for (final cls in exports.classes) {
      alias(cls.name, cls.typeParameters);
    }
    for (final enumeration in exports.enums) {
      alias(enumeration.name, const []);
    }
    if (aliases.isNotEmpty) {
      output.writeln('declare namespace $binding {');
      for (final entry in aliases.entries) {
        final parameters = entry.value.parameters;
        output.writeln(
          '  type ${entry.key}${_generics(parameters)} = ${entry.value.alias}${_parameterArguments(parameters)};',
        );
      }
      output.writeln('}');
    }
    output.writeln(esm ? 'export default $binding;' : 'export = $binding;');
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
      ValueKind.integer ||
      ValueKind.doubleValue ||
      ValueKind.number => 'number',
      ValueKind.string => 'string',
      ValueKind.bigint => 'bigint',
      ValueKind.nullValue => 'null',
      ValueKind.voidValue => 'void',
      ValueKind.never => 'never',
      ValueKind.typeParameter => _parameterNames[type.parameter!.target]!,
      ValueKind.object =>
        '${type.classExport!.isObject && !output ? _input(type.classExport!) : type.classExport!.name}'
            '${type.typeArguments.isEmpty ? '' : '<${type.typeArguments.map((argument) => _type(argument, output: output)).join(', ')}>'}',
      ValueKind.enumeration => type.enumExport!.name,
      ValueKind.undefined => 'undefined',
      ValueKind.dynamicValue => 'any',
      ValueKind.opaque => type.nullable ? 'unknown' : '({} | undefined)',
      ValueKind.jsReference => switch (type.referenceKind!) {
        JsReferenceKind.object => 'object',
        JsReferenceKind.function => 'globalThis.Function',
        JsReferenceKind.symbol => 'symbol',
      },
      ValueKind.function =>
        '(${_generics(type.signature!.typeParameters, defaults: false)}(${_parameters(type.signature!, output: output)}) => ${_type(type.signature!.result, output: output)})',
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
    return type.nullable && type.kind != ValueKind.opaque
        ? '$value | null'
        : value;
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
}

String _label(String name, int index) =>
    RegExp(r'^[a-zA-Z_$][a-zA-Z0-9_$]*$').hasMatch(name) ? name : 'arg$index';

String _member(String name) => name == 'constructor' ? '["constructor"]' : name;

const _reservedParameterNames = {
  'any',
  'unknown',
  'never',
  'number',
  'bigint',
  'boolean',
  'string',
  'symbol',
  'void',
  'object',
  'undefined',
  'globalThis',
};
