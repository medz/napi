import 'dart:convert';

import '../emit/dart/entrypoint.dart' show renderDartDefault;
import '../ir/model.dart';
import '../lowering/plan.dart' show ScalarConversion, ScalarKind;
import 'plan.dart';

String _quote(String value) => jsonEncode(value).replaceAll(r'$', r'\$');

/// Generate business-specific Dart only. The Node-API bridge stays generic.
String emitNativeDart(NativeModulePlan plan) {
  final code = StringBuffer('''
import 'package:napi/src/compiler/native/bindings.dart';
import ${_quote(plan.bindings.importUri.toString())} as target;

late final NapiApi _api;
@pragma('vm:entry-point')
List<Object?> napiBindings(int apiTableAddress, int tableCount) {
  _api = NapiApi(apiTableAddress, tableCount);
  return [
''');
  for (final function in plan.functions) {
    code.writeln(
      "    ['function', ${_quote(function.function!.exportName)}, ${function.callback}, ${function.javascriptArity}],",
    );
  }
  for (final binding in plan.classes) {
    code.writeln(
      "    ['class', ${_quote(binding.binding.exportName)}, ${binding.constructor.callback}, [",
    );
    for (final member in binding.members) {
      final kind = member.kind.name;
      final metadataKind = member.isStatic
          ? 'static${kind[0].toUpperCase()}${kind.substring(1)}'
          : kind;
      code.writeln(
        '      [${_quote(metadataKind)}, ${_quote(member.exportName)}, ${member.callback}, ${member.javascriptArity}],',
      );
    }
    code.writeln('    ], ${binding.constructor.javascriptArity}],');
  }
  code.writeln('''  ];
}
@pragma('vm:entry-point')
void releaseOwner(int id) => _api.releaseOwner(id);
void main() {}
''');
  for (final call in plan.calls) {
    final parameters = call.parameters;
    final positionalCount = parameters.where((p) => !_named(p)).length;
    final named = parameters.where(_named).toList();
    final capacity = positionalCount + (named.isEmpty ? 0 : 1);
    code.writeln(
      'int ${call.callback}(int envAddress, int infoAddress) {\n  try {',
    );
    code.writeln(
      '    final call = _api.call(envAddress, infoAddress, $capacity);',
    );
    code.writeln(
      '    _api.checkNew(call, ${call.isConstructor}, ${_quote(call.context)});',
    );
    if (call.owner != null && !call.isConstructor && !call.isStatic) {
      code.writeln('    final object = _api.owner(call);');
      code.writeln(
        '    if (object is! target.${call.owner!.callPath}) throw NapiTypeError(${_quote('${call.context}: invalid native receiver')});',
      );
    }
    if (named.isNotEmpty) {
      code.writeln(
        '    final options = _api.options(call, $positionalCount, ${jsonEncode(named.map((p) => p.name).toList())}, ${_quote('${call.context} options')});',
      );
    }
    var namedIndex = 0;
    for (final (index, parameter) in parameters.indexed) {
      final conversion = call.inputs[index];
      final path = _quote(conversion.context);
      final isNamed = _named(parameter);
      final option = namedIndex;
      if (isNamed) namedIndex++;
      final raw = isNamed
          ? '_api.requiredOption(call.env, options, $option, $path)'
          : '_api.requiredArgument(call, $index, $path)';
      code.writeln('    final ${conversion.dartType} a$index;');
      if (_optional(parameter)) {
        final defaulted = isNamed
            ? '_api.defaultOption(call.env, options, $option)'
            : '_api.omittedOrUndefined(call, $index)';
        code.writeln(
          '    if ($defaulted) {\n      a$index = ${renderDartDefault(parameter, conversion)};\n    } else {',
        );
      }
      code.writeln('    final raw$index = $raw;');
      final converted =
          '_api.${_reader(conversion)}(call.env, raw$index, $path)';
      code.writeln(
        '    a$index = ${conversion.nullable ? '_api.isNull(call.env, raw$index) ? null : ' : ''}$converted;',
      );
      if (_optional(parameter)) code.writeln('    }');
    }
    final arguments = [
      for (final (index, parameter) in parameters.indexed)
        '${_named(parameter) ? '${parameter.name}: ' : ''}a$index',
    ].join(', ');
    final receiver = call.owner == null
        ? 'target'
        : call.isStatic || call.isConstructor
        ? 'target.${call.owner!.callPath}'
        : 'object';
    final path =
        call.function?.callPath ??
        call.member?.callPath ??
        call.member?.declaration.name;
    final invocation = switch (call.kind) {
      NativeCallKind.function => 'target.$path($arguments)',
      NativeCallKind.constructor => '$receiver($arguments)',
      NativeCallKind.method => '$receiver.$path($arguments)',
      NativeCallKind.getter => '$receiver.$path',
      NativeCallKind.setter => '$receiver.$path = a0',
    };
    if (call.isConstructor) {
      code.writeln('    return _api.wrap(call, $invocation);');
    } else if (call.output == null) {
      code.writeln(
        '    $invocation;\n    return _api.undefinedResult(call.env);',
      );
    } else {
      final output = call.output!;
      code.writeln('    final value = $invocation;');
      if (output.nullable) {
        code.writeln(
          '    if (value == null) return _api.nullResult(call.env);',
        );
      }
      final context = output.kind == ScalarKind.integer && !output.usesBigInt
          ? ', ${_quote(output.context)}'
          : '';
      code.writeln(
        '    return _api.${_writer(output)}(call.env, value$context);',
      );
    }
    code.writeln(
      '  } catch (error) {\n    return _api.fail(envAddress, error);\n  }\n}',
    );
  }
  return code.toString();
}

bool _named(ParameterBinding p) =>
    p.kind == ParameterKind.requiredNamed ||
    p.kind == ParameterKind.optionalNamed;
bool _optional(ParameterBinding p) =>
    p.kind == ParameterKind.optionalNamed ||
    p.kind == ParameterKind.optionalPositional;
String _reader(ScalarConversion value) => switch (value.kind) {
  ScalarKind.integer => value.bigint ? 'integerBigInt' : 'integer',
  ScalarKind.boolean => 'boolean',
  ScalarKind.string => 'string',
  ScalarKind.doubleValue => 'doubleValue',
  ScalarKind.bigInteger => 'bigInteger',
};
String _writer(ScalarConversion value) => switch (value.kind) {
  ScalarKind.integer => value.bigint ? 'integerBigIntResult' : 'integerResult',
  ScalarKind.boolean => 'booleanResult',
  ScalarKind.string => 'stringResult',
  ScalarKind.doubleValue => 'doubleResult',
  ScalarKind.bigInteger => 'bigIntegerResult',
};
