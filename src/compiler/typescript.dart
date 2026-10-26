import 'dart:convert';

import 'exports.dart';

String typeScriptDeclarations(List<ExportFunction> exports) {
  final output = StringBuffer();
  for (var index = 0; index < exports.length; ++index) {
    final function = exports[index];
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
      if (options != null) {
        tuples.add('[${[...parameters, 'options: $options'].join(', ')}]');
      }
    }
    output.writeln(
      'export declare function ${function.name}(...args: ${tuples.join(' | ')}): ${_type(function.result)};',
    );
  }
  return output.toString();
}

String _type(ExportType type) {
  final value = switch (type.kind) {
    ScalarKind.boolean => 'boolean',
    ScalarKind.integer ||
    ScalarKind.doubleValue ||
    ScalarKind.number => 'number',
    ScalarKind.string => 'string',
    ScalarKind.bigint => 'bigint',
    ScalarKind.nullValue => 'null',
    ScalarKind.voidValue => 'void',
    ScalarKind.never => 'never',
  };
  return type.nullable ? '$value | null' : value;
}

String _label(String name, int index) =>
    RegExp(r'^[a-zA-Z_$][a-zA-Z0-9_$]*$').hasMatch(name) ? name : 'arg$index';
