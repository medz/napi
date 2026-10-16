import 'dart:convert';

import '../../lowering/plan.dart';
import '../../ir/model.dart';
import '../../sdk_adapter/entrypoint.dart';

String emitDart(ModulePlan plan) {
  final source = jsonEncode(plan.source.toString()).replaceAll(r'$', r'\$');
  final result = StringBuffer(
    "import $source as target;\n$entrypointPrelude\n",
  );
  var context = 0;
  for (var index = 0; index < plan.functions.length; index++) {
    final function = plan.functions[index];
    final parameters = function.binding.parameters;
    result.writeln("@pragma('wasm:export', '${function.coreExportName}')");
    result.writeln(
      'WasmExternRef? _export$index(${[
        for (var i = 0; i < parameters.length; i++) ...[if (_optional(parameters[i])) 'WasmI32 d$i', 'WasmExternRef? p$i'],
      ].join(', ')}) {',
    );
    // Validate raw externrefs outside the Dart exception boundary. In
    // particular undefined is not erased into Dart null before validation.
    for (var i = 0; i < parameters.length; i++) {
      final conversion = function.inputs[i];
      result.writeln('  final ${conversion.dartType} a$i;');
      if (_optional(parameters[i])) {
        result.writeln('  if (d$i.toIntSigned() != 0) {');
        result.writeln('    a$i = ${_default(parameters[i], conversion)};');
        result.writeln('  } else {');
      }
      result.writeln(
        '  final v$i = _readValue(p$i, WasmI32.fromInt(${context++}));',
      );
      final value = _read(conversion, 'v$i!');
      result.writeln(
        '  a$i = '
        '${conversion.nullable ? 'v$i.isNull ? null : ' : ''}$value;',
      );
      if (_optional(parameters[i])) result.writeln('  }');
    }
    result.writeln('  ${function.output.dartType} value;\n  try {');
    result.writeln(
      '    value = target.${function.binding.callPath}(${[for (var i = 0; i < parameters.length; i++) '${_named(parameters[i]) ? '${parameters[i].name}: ' : ''}a$i'].join(', ')});',
    );
    result.writeln(
      '  } catch (error) {\n    return _normalizeError(error);\n  }',
    );
    if (function.output.nullable) {
      result.writeln('  if (value == null) return WasmExternRef.nullRef;');
    }
    result.writeln('  return ${_write(function.output, context++)};\n}');
  }
  return result.toString();
}

bool _optional(ParameterBinding p) =>
    p.kind == ParameterKind.optionalPositional ||
    p.kind == ParameterKind.optionalNamed;

bool _named(ParameterBinding p) =>
    p.kind == ParameterKind.requiredNamed ||
    p.kind == ParameterKind.optionalNamed;

String _default(ParameterBinding p, ScalarConversion conversion) {
  final value = p.defaultValue?.value;
  if (value == null) return 'null';
  if (value is String) return jsonEncode(value).replaceAll(r'$', r'\$');
  if (value is double) {
    if (value.isNaN) return 'double.nan';
    if (value.isInfinite) {
      return value.isNegative ? 'double.negativeInfinity' : 'double.infinity';
    }
  }
  if (value is int && conversion.kind == ScalarKind.doubleValue) {
    return value.toDouble().toString();
  }
  return value.toString();
}

String _read(ScalarConversion conversion, String value) {
  if (conversion.usesBigInt) {
    final parse = conversion.kind == ScalarKind.integer ? 'int' : 'BigInt';
    return '$parse.parse((_readBigInt($value).toJS as JSString).toDart)';
  }
  return switch (conversion.kind) {
    ScalarKind.boolean => '($value.toJS as JSBoolean).toDart',
    ScalarKind.string => '($value.toJS as JSString).toDart',
    ScalarKind.integer => '($value.toJS as JSNumber).toDartDouble.toInt()',
    ScalarKind.doubleValue => '($value.toJS as JSNumber).toDartDouble',
    ScalarKind.bigInteger => throw StateError('Handled above'),
  };
}

String _write(ScalarConversion conversion, int context) {
  final value = conversion.usesBigInt ? 'value.toString().toJS' : 'value.toJS';
  final method = conversion.usesBigInt ? '_writeBigInt' : '_writeValue';
  return '$method(externRefForJSAny($value)${conversion.usesBigInt ? '!' : ''}, WasmI32.fromInt($context))';
}
