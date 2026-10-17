import 'dart:convert';

import '../../lowering/plan.dart';
import '../../ir/model.dart';
import '../../sdk_adapter/entrypoint.dart';
import 'structural.dart';

String emitDart(ModulePlan plan) {
  final source = jsonEncode(plan.source.toString()).replaceAll(r'$', r'\$');
  final result = StringBuffer(
    "import $source as target;\n"
    "${plan.conversions.any(containsDictionary) ? "import 'package:napi/napi.dart' as napi;\nimport 'dart:convert' show jsonEncode;\n" : ''}"
    '$entrypointPrelude\n',
  );
  if (plan.classes.isNotEmpty) {
    result.writeln('const _referenceMemberships = <Set<int>>[');
    for (final binding in plan.classes) {
      result.writeln('  {${binding.shape.memberships.join(', ')}},');
    }
    result.writeln('''
];
@pragma('wasm:export', 'napi:class:classify')
WasmI32 _classifyReference(WasmExternRef reference) {
  final object = reference.internalize().toObject();
  var candidate = -1;
  var ambiguous = false;
''');
    for (final classId in plan.referenceClassOrder) {
      result.writeln('''
  if (object is target.${plan.classes[classId].binding.callPath}) {
    if (candidate < 0) {
      candidate = $classId;
    } else if (!_referenceMemberships[candidate].contains($classId)) {
      ambiguous = true;
    }
  }
''');
    }
    result.writeln('  return WasmI32.fromInt(ambiguous ? -1 : candidate);\n}');
  }
  final structural = DartStructuralEmitter();
  final hasStructural = plan.conversions.any(
    (c) =>
        c is ListConversion ||
        c is RecordConversion ||
        c is MapConversion ||
        c is DictionaryConversion ||
        c is ValueClassConversion,
  );
  if (hasStructural) result.writeln(dartStructuralPrelude);
  for (final (index, call) in plan.calls.indexed) {
    final parameters = call.parameters;
    final output = call.output;
    final constructor =
        call is MemberCallPlan && call.kind == MemberCallKind.constructor;
    final instance = call is MemberCallPlan && !constructor && !call.isStatic;
    final returnsVoid = output == null && !constructor;
    result.writeln("@pragma('wasm:export', '${call.coreExportName}')");
    result.writeln(
      '${returnsVoid ? 'void' : 'WasmExternRef?'} _export$index(${[
        if (instance) 'WasmExternRef reference',
        for (var i = 0; i < parameters.length; i++) ...[if (_optional(parameters[i])) 'WasmI32 d$i', 'WasmExternRef? p$i'],
      ].join(', ')}) {',
    );
    // Raw externrefs are validated before Dart can erase undefined into null.
    for (var i = 0; i < parameters.length; i++) {
      final conversion = call.inputs[i];
      result.writeln('  final ${conversion.dartType} a$i;');
      if (_optional(parameters[i])) {
        result.writeln('  if (d$i.toIntSigned() != 0) {');
        result.writeln(
          '    a$i = ${renderDartDefault(parameters[i], conversion)};',
        );
        result.writeln('  } else {');
      }
      if (conversion is ReferenceConversion) {
        result.writeln(
          '  a$i = ${conversion.nullable ? 'p$i.isNull ? null : ' : ''}p$i!.internalize().toObject() as ${conversion.dartType};',
        );
      } else {
        result.writeln(
          '  final v$i = _readValue(p$i, WasmI32.fromInt(${call.inputContexts[i]}));',
        );
        final value = conversion is ScalarConversion
            ? _read(conversion, 'v$i!')
            : '${structural.read(conversion)}(v$i.isNull ? null : v$i!.toJS, ${jsonEncode(conversion.context).replaceAll(r'$', r'\$')})';
        if (conversion is! ScalarConversion) result.writeln('  try {');
        result.writeln(
          '  a$i = ${conversion.nullable && conversion is ScalarConversion ? 'v$i.isNull ? null : ' : ''}$value;',
        );
        if (conversion is! ScalarConversion) {
          result.writeln('  } on _StructureViolation catch (error) {');
          result.writeln(
            returnsVoid
                ? '    _reportStructureError(error);\n    return;'
                : '    return _reportStructureError(error);',
          );
          result.writeln('  } catch (error) {');
          result.writeln(
            returnsVoid
                ? '    _normalizeError(error);\n    return;'
                : '    return _normalizeError(error);',
          );
          result.writeln('  }');
        }
      }
      if (_optional(parameters[i])) result.writeln('  }');
    }
    if (output != null) result.writeln('  ${output.dartType} value;');
    result.writeln('  try {');
    if (instance) {
      final owner = call.owner;
      result.writeln(
        '    final object = reference.internalize().toObject() as target.${owner.callPath};',
      );
    }
    final invocation = _invocation(call);
    if (constructor) {
      result.writeln('    final value = $invocation;');
      result.writeln('    return WasmAnyRef.fromObject(value).externalize();');
    } else if (returnsVoid) {
      result.writeln('    $invocation;');
    } else {
      result.writeln('    value = $invocation;');
    }
    result.writeln('  } catch (error) {');
    result.writeln(
      returnsVoid
          ? '    _normalizeError(error);'
          : '    return _normalizeError(error);',
    );
    result.writeln('  }');
    if (output == null) {
      result.writeln('}');
      continue;
    }
    if (output.nullable) {
      result.writeln('  if (value == null) return WasmExternRef.nullRef;');
    }
    final context = call.outputContext!;
    if (output is ReferenceConversion) {
      result.writeln('  return WasmAnyRef.fromObject(value).externalize();\n}');
    } else if (output case final ScalarConversion scalar) {
      result.writeln('  return ${_write(scalar, context)};\n}');
    } else {
      final writer = structural.write(output);
      final path = jsonEncode(output.context).replaceAll(r'$', r'\$');
      result.writeln(
        '  final JSAny? serialized;\n'
        '  try {\n'
        '    serialized = $writer(value, _StructureState(), $path, 0);\n'
        '  } on _StructureViolation catch (error) {\n'
        '    return _reportStructureError(error);\n'
        '  } catch (error) {\n'
        '    return _normalizeError(error);\n'
        '  }\n'
        '  return _writeValue(externRefForJSAny(serialized!), WasmI32.fromInt($context));\n}',
      );
    }
  }
  result.write(structural.source);
  return result.toString();
}

String _invocation(CallPlan call) {
  final arguments = [
    for (final (index, parameter) in call.parameters.indexed)
      '${_named(parameter) ? '${parameter.name}: ' : ''}a$index',
  ].join(', ');
  if (call is FunctionPlan) {
    return 'target.${call.binding.callPath}($arguments)';
  }
  final member = call as MemberCallPlan;
  final receiver = member.isStatic || member.kind == MemberCallKind.constructor
      ? 'target.${member.owner.callPath}'
      : 'object';
  final path = member.binding.callPath ?? member.binding.declaration.name;
  return switch (member.kind) {
    MemberCallKind.constructor =>
      member.binding.declaration.name == 'new'
          ? '$receiver($arguments)'
          : '$receiver.$path($arguments)',
    MemberCallKind.method => '$receiver.$path($arguments)',
    MemberCallKind.getter => '$receiver.$path',
    MemberCallKind.setter => '$receiver.$path = a0',
  };
}

bool _optional(ParameterBinding p) =>
    p.kind == ParameterKind.optionalPositional ||
    p.kind == ParameterKind.optionalNamed;

bool _named(ParameterBinding p) =>
    p.kind == ParameterKind.requiredNamed ||
    p.kind == ParameterKind.optionalNamed;

String renderDartDefault(ParameterBinding p, ValueConversion conversion) {
  final value = p.defaultValue?.value;
  if (value == null) return 'null';
  if (value is String) return jsonEncode(value).replaceAll(r'$', r'\$');
  if (value is double) {
    if (value.isNaN) return 'double.nan';
    if (value.isInfinite) {
      return value.isNegative ? 'double.negativeInfinity' : 'double.infinity';
    }
  }
  if (value is int &&
      conversion is ScalarConversion &&
      conversion.kind == ScalarKind.doubleValue) {
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
