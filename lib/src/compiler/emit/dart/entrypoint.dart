import 'dart:convert';

import '../../analysis/reference_views.dart';
import '../../lowering/plan.dart';
import '../../ir/model.dart';
import '../../sdk_adapter/entrypoint.dart';
import 'structural.dart';

String emitDart(ModulePlan plan) {
  final resources = plan.resourcePolicies.isNotEmpty;
  final callbacks = {
    for (final (index, conversion) in plan.conversions.indexed)
      if (conversion is CallbackConversion) index: conversion,
  };
  final prelude = callbacks.isEmpty
      ? entrypointPrelude
      : withCallbackErrors(entrypointPrelude);
  final source = jsonEncode(plan.source.toString()).replaceAll(r'$', r'\$');
  final result = StringBuffer(
    "import $source as target;\n"
    "${resources ? "import 'package:napi/runtime.dart';\n" : ''}"
    "${plan.conversions.any(containsDictionary) ? "import 'package:napi/napi.dart' as napi;\nimport 'dart:convert' show jsonEncode;\n" : ''}"
    '$prelude\n',
  );
  if (plan.classes.any((c) => c.binding.typeParameters.any((p) => p.opaque)) ||
      plan.functions.any(
        (f) => f.binding.typeParameters.any((p) => p.opaque),
      )) {
    result.writeln(opaqueEntrypointPrelude);
  }
  if (plan.calls.any((call) => call.returnsFuture)) {
    result.writeln(
      callbacks.isEmpty
          ? futureEntrypointPrelude
          : withCallbackErrors(futureEntrypointPrelude),
    );
  }
  if (callbacks.isNotEmpty) result.writeln(callbackEntrypointPrelude);
  if (resources) {
    result.writeln(resourceEntrypointPrelude);
    _emitResourceControl(result, plan);
  }
  if (plan.classes.isNotEmpty) {
    final candidates = [for (final _ in plan.classes) <int>[]];
    for (final binding in plan.classes) {
      for (final id in binding.shape.memberships) {
        candidates[id].add(binding.shape.classId);
      }
    }
    result.writeln('''
@pragma('wasm:export', 'napi:class:classify')
WasmI32 _classifyReference(WasmExternRef reference) {
  final object = reference.internalize().toObject();
${resources ? '  try { _resourceControl(object); } catch (error) { _normalizeResourceError(error); }\n' : ''}  var candidate = -1;
  var ambiguous = false;
''');
    for (final classId in plan.referenceClassOrder) {
      result.writeln('''
  if (object is ${dartReferenceClassType(plan.classes[classId].binding)}) {
    if (candidate < 0) {
      candidate = $classId;
    } else if (${candidates[classId].map((id) => 'candidate != $id').join(' && ')}) {
      ambiguous = true;
    }
  }
''');
    }
    result.writeln('  return WasmI32.fromInt(ambiguous ? -1 : candidate);\n}');
    if (hasCompositeReferenceViews(plan.classes.map((c) => c.shape).toList())) {
      result.writeln('''
@pragma('wasm:export', 'napi:class:views')
WasmExternRef _referenceViews(WasmExternRef reference) {
  final object = reference.internalize().toObject();
  return externRefForJSAny(<JSAny?>[
''');
      for (final (id, binding) in plan.classes.indexed) {
        result.writeln(
          '    if (object is ${dartReferenceClassType(binding.binding)}) $id.toJS,',
        );
      }
      result.writeln('  ].toJS)!;\n}');
    }
  }
  final structural = DartStructuralEmitter();
  final hasStructural =
      callbacks.isNotEmpty ||
      plan.conversions.any(
        (c) =>
            c is ListConversion ||
            c is RecordConversion ||
            c is MapConversion ||
            c is DictionaryConversion ||
            c is ValueClassConversion,
      );
  if (hasStructural) result.writeln(dartStructuralPrelude);
  for (final entry in callbacks.entries) {
    _emitCallbackAdapter(result, structural, entry.value, entry.key);
  }
  for (final (index, call) in plan.calls.indexed) {
    final parameters = call.parameters;
    final output = call.output;
    final errorContext = jsonEncode(
      call is FunctionPlan
          ? call.binding.exportName
          : (call as MemberCallPlan).context,
    ).replaceAll(r'$', r'\$');
    if (plan.needsResourceOperation(call)) {
      _emitResourceCall(result, structural, call, index, errorContext);
      continue;
    }
    final constructor =
        call is MemberCallPlan && call.kind == MemberCallKind.constructor;
    final instance = call is MemberCallPlan && !constructor && !call.isStatic;
    final returnsVoid = call.returnsFuture || (output == null && !constructor);
    result.writeln("@pragma('wasm:export', '${call.coreExportName}')");
    result.writeln(
      '${returnsVoid ? 'void' : 'WasmExternRef?'} _export$index(${[
        if (call.returnsFuture) 'WasmExternRef capability',
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
      if (conversion is CallbackConversion) {
        result.writeln(
          '  a$i = ${conversion.nullable ? 'p$i.isNull ? null : ' : ''}_callback${call.inputContexts[i]}(p$i!);',
        );
      } else if (conversion is OpaqueConversion) {
        result.writeln('  a$i = _NapiHostValue(p$i);');
      } else if (conversion is ReferenceConversion) {
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
          result.writeln(
            '  } catch (error${call.returnsFuture ? ', stack' : ''}) {',
          );
          result.writeln(
            call.returnsFuture
                ? '    _failFuture(capability, error, stack, $errorContext);\n    return;'
                : returnsVoid
                ? '    _normalizeError(error);\n    return;'
                : '    return _normalizeError(error);',
          );
          result.writeln('  }');
        }
      }
      if (_optional(parameters[i])) result.writeln('  }');
    }
    if (call.returnsFuture) {
      result.writeln('  Future<${output?.dartType ?? 'void'}> value;');
    } else if (output != null) {
      result.writeln('  ${output.dartType} value;');
    }
    result.writeln('  try {');
    if (instance) {
      final owner = call.owner;
      result.writeln(
        '    final object = reference.internalize().toObject() as ${dartReferenceClassType(owner)};',
      );
    }
    final invocation = _invocation(call);
    if (call.returnsFuture) {
      result.writeln(
        '    _retainPromise(capability, WasmAnyRef.fromObject(<Object?>[${[if (instance) 'object', for (var i = 0; i < parameters.length; i++) 'a$i'].join(', ')}]).externalize());',
      );
      result.writeln('    value = $invocation;');
    } else if (constructor) {
      result.writeln('    final value = $invocation;');
      result.writeln('    return WasmAnyRef.fromObject(value).externalize();');
    } else if (returnsVoid) {
      result.writeln('    $invocation;');
    } else {
      result.writeln('    value = $invocation;');
    }
    result.writeln('  } catch (error${call.returnsFuture ? ', stack' : ''}) {');
    result.writeln(
      call.returnsFuture
          ? '    _failFuture(capability, error, stack, $errorContext);\n    return;'
          : returnsVoid
          ? '    _normalizeError(error);'
          : '    return _normalizeError(error);',
    );
    result.writeln('  }');
    if (call.returnsFuture) {
      result.writeln(
        '  _observeFuture(value, capability, $errorContext, ${output == null ? 'null' : '(value) => _futureJSValue(_futureOutput$index(value))'});\n}',
      );
      if (output != null) {
        result.writeln(
          'WasmExternRef? _futureOutput$index(${output.dartType} value) {',
        );
      } else {
        continue;
      }
    }
    if (output == null) {
      result.writeln('}');
      continue;
    }
    if (output.nullable) {
      result.writeln('  if (value == null) return WasmExternRef.nullRef;');
    }
    final context = call.outputContext!;
    if (output is OpaqueConversion) {
      result.writeln('  return value.value;\n}');
    } else if (output is ReferenceConversion) {
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
        '  } catch (error${call.returnsFuture ? ', stack' : ''}) {\n'
        '    return ${call.returnsFuture ? '_normalizeFutureError(error, stack, $errorContext)' : '_normalizeError(error)'};\n'
        '  }\n'
        '  return _writeValue(externRefForJSAny(serialized!), WasmI32.fromInt($context));\n}',
      );
    }
  }
  result.write(structural.source);
  return result.toString();
}

void _emitCallbackAdapter(
  StringBuffer result,
  DartStructuralEmitter structural,
  CallbackConversion callback,
  int context,
) {
  String quote(String value) => jsonEncode(value).replaceAll(r'$', r'\$');
  final parameters = [
    for (final (index, conversion) in callback.inputs.indexed)
      '${conversion.dartType} c$index',
  ].join(', ');
  final arguments = [
    for (final (index, conversion) in callback.inputs.indexed)
      '${structural.write(conversion)}(c$index, _StructureState(), ${quote(conversion.context)}, 0)',
  ].join(', ');
  result.writeln(
    '''${callback.dartType} _callback$context(WasmExternRef borrowed) {
  return ($parameters) {
    if (_callbackActive(borrowed).toIntSigned() == 0) {
      throw StateError(${quote('${callback.context}: borrowed callback has expired')});
    }
    final JSArray<JSAny?> arguments;
    try {
      arguments = <JSAny?>[$arguments].toJS;
    } on _StructureViolation catch (error) {
      throw _CallbackThrown(_callbackStructureError(externRefForJSAny(error.path.toJS)!, externRefForJSAny(error.message.toJS)!, WasmI32.fromInt(error.range ? 1 : 0)));
    }
    final envelope = _invokeCallback(borrowed, externRefForJSAny(arguments)!, WasmI32.fromInt($context));
    if (_callbackThrew(envelope).toIntSigned() != 0) throw _CallbackThrown(envelope);''',
  );
  if (callback.output case final output?) {
    final read = structural.read(output, bigintText: true);
    result.writeln(
      '''    final value = _callbackValue(envelope);
    return $read(value.isNull ? null : value!.toJS, ${quote(output.context)});''',
    );
  }
  result.writeln('  };\n}');
}

void _emitResourceControl(StringBuffer result, ModulePlan plan) {
  result.writeln('ResourceControl? _resourceControl(Object? value) {');
  result.writeln('  if (value == null) return null;');
  result.writeln('  var policy = -1;');
  for (final entry in plan.resourcePolicies.entries) {
    result.writeln(
      '''  if (value is ${dartReferenceClassType(plan.classes[entry.key].binding)}) {
    if (policy >= 0 && policy != ${entry.value}) throw const _ResourcePolicyViolation();
    policy = ${entry.value};
  }''',
    );
  }
  result.writeln(
    '  return policy < 0 ? null : ResourceControl.forObject(value);\n}',
  );
}

void _emitResourceCall(
  StringBuffer result,
  DartStructuralEmitter structural,
  CallPlan call,
  int index,
  String errorContext,
) {
  final member = call is MemberCallPlan ? call : null;
  final constructor = member?.kind == MemberCallKind.constructor;
  final instance = member != null && !member.isStatic;
  final cleanup = member?.isCleanup ?? false;
  final output = call.output;
  final returnsVoid = call.returnsFuture || (output == null && !constructor);
  final returnType = returnsVoid ? 'void' : 'WasmExternRef?';
  void catchDartError() {
    result.writeln('  } catch (error${call.returnsFuture ? ', stack' : ''}) {');
    result.writeln(
      call.returnsFuture
          ? '    _failResourceFuture(capability, error, stack, $errorContext);\n    return;'
          : returnsVoid
          ? '    _normalizeResourceError(error);\n    return;'
          : '    return _normalizeResourceError(error);',
    );
    result.writeln('  }');
  }

  result.writeln("@pragma('wasm:export', '${call.coreExportName}')");
  result.writeln(
    '$returnType _export$index(${[
      'WasmExternRef capability',
      'WasmExternRef prepared',
      if (instance) 'WasmExternRef reference',
      for (final (i, parameter) in call.parameters.indexed) ...[if (_optional(parameter)) 'WasmI32 d$i', 'WasmExternRef? p$i'],
    ].join(', ')}) {',
  );
  result.writeln(
    '  final operation = prepared.internalize().toObject() as ResourceOperation;',
  );
  if (instance) {
    result.writeln(
      '  final object = reference.internalize().toObject() as ${dartReferenceClassType(member.owner)};',
    );
    if (cleanup) result.writeln('  final control = _resourceControl(object);');
  }
  for (final (i, parameter) in call.parameters.indexed) {
    final conversion = call.inputs[i];
    result.writeln('  final ${conversion.dartType} a$i;');
    if (_optional(parameter)) {
      result.writeln(
        '  if (d$i.toIntSigned() != 0) {\n    a$i = ${renderDartDefault(parameter, conversion)};\n  } else {',
      );
    }
    if (conversion is CallbackConversion) {
      result.writeln(
        '  a$i = ${conversion.nullable ? 'p$i.isNull ? null : ' : ''}_callback${call.inputContexts[i]}(p$i!);',
      );
    } else if (conversion is OpaqueConversion) {
      result.writeln('  a$i = _NapiHostValue(p$i);');
    } else if (conversion is ReferenceConversion) {
      result.writeln(
        '  a$i = ${conversion.nullable ? 'p$i.isNull ? null : ' : ''}p$i!.internalize().toObject() as ${conversion.dartType};',
      );
    } else {
      // JS snapshots may throw any value. Keep imports outside Dart catch so
      // the host's Promise/finally boundary receives their original identity.
      result.writeln(
        '  final v$i = _readResourceValue(capability, p$i, WasmI32.fromInt(${call.inputContexts[i]}));',
      );
      final value = conversion is ScalarConversion
          ? '${conversion.nullable ? 'v$i.isNull ? null : ' : ''}${_read(conversion, 'v$i!')}'
          : '${structural.read(conversion)}(v$i.isNull ? null : v$i!.toJS, ${jsonEncode(conversion.context).replaceAll(r'$', r'\$')})';
      if (conversion is! ScalarConversion) result.writeln('  try {');
      result.writeln('  a$i = $value;');
      if (conversion is! ScalarConversion) {
        result.writeln('  } on _StructureViolation catch (error) {');
        result.writeln(
          returnsVoid
              ? '    _reportStructureError(error);\n    return;'
              : '    return _reportStructureError(error);',
        );
        catchDartError();
      }
    }
    if (_optional(parameter)) result.writeln('  }');
  }
  if (cleanup) {
    result.writeln(
      '  if (_bindCleanup(capability, WasmAnyRef.fromObject(control!).externalize()).toIntSigned() == 0) return;',
    );
  }
  if (call.returnsFuture) {
    result.writeln(
      '  _activateResourceOperation(capability, WasmI32.fromInt(operation.isEmpty ? 0 : 1));',
    );
    result.writeln(
      '  _retainPromise(capability, WasmAnyRef.fromObject(<Object?>[${[if (instance) 'object', for (var i = 0; i < call.parameters.length; i++) 'a$i'].join(', ')}]).externalize());',
    );
    result.writeln('  final Future<${output?.dartType ?? 'void'}> value;');
  } else if (constructor) {
    result.writeln('  final ${dartReferenceClassType(member!.owner)} value;');
  } else if (output != null) {
    result.writeln('  final ${output.dartType} value;');
  }
  final invocation = _invocation(call);
  final invoke = cleanup ? 'control.dispose(() => $invocation)' : invocation;
  result.writeln('  try {');
  result.writeln(
    '    ${call.returnsFuture || constructor || output != null ? 'value = ' : ''}$invoke;',
  );
  catchDartError();
  if (call.returnsFuture) {
    result.writeln(
      '  _observeFuture(value, capability, $errorContext, ${output == null ? 'null' : '(value) => _futureJSValue(_futureOutput$index(value))'});\n}',
    );
    if (output == null) return;
    result.writeln(
      'WasmExternRef? _futureOutput$index(${output.dartType} value) {',
    );
  } else if (constructor) {
    result.writeln('  return WasmAnyRef.fromObject(value).externalize();\n}');
    return;
  }
  if (output != null) {
    _emitResourceOutput(
      result,
      structural,
      output,
      call.outputContext!,
      '  ',
      futureContext: call.returnsFuture ? errorContext : null,
    );
  }
  result.writeln('}');
}

void _emitResourceOutput(
  StringBuffer result,
  DartStructuralEmitter structural,
  ValueConversion output,
  int context,
  String indent, {
  String? futureContext,
}) {
  if (output.nullable) {
    result.writeln('${indent}if (value == null) return WasmExternRef.nullRef;');
  }
  if (output is OpaqueConversion) {
    result.writeln('${indent}return value.value;');
  } else if (output is ReferenceConversion) {
    result.writeln(
      '${indent}return WasmAnyRef.fromObject(value).externalize();',
    );
  } else if (output is ScalarConversion) {
    result.writeln('${indent}return ${_write(output, context)};');
  } else {
    result.writeln('${indent}final JSAny? serialized;');
    result.writeln('${indent}try {');
    result.writeln(
      '$indent  serialized = ${structural.write(output)}(value, _StructureState(), ${jsonEncode(output.context).replaceAll(r'$', r'\$')}, 0);',
    );
    result.writeln('$indent} on _StructureViolation catch (error) {');
    result.writeln('$indent  return _reportStructureError(error);');
    result.writeln(
      '$indent} catch (error${futureContext != null ? ', stack' : ''}) {',
    );
    result.writeln(
      '$indent  return ${futureContext == null ? '_normalizeResourceError(error)' : '_normalizeFutureError(error, stack, $futureContext)'};',
    );
    result.writeln('$indent}');
    result.writeln(
      '${indent}return _writeValue(externRefForJSAny(serialized!), WasmI32.fromInt($context));',
    );
  }
}

String _invocation(CallPlan call) {
  final arguments = [
    for (final (index, parameter) in call.parameters.indexed)
      '${_named(parameter) ? '${parameter.name}: ' : ''}a$index',
  ].join(', ');
  if (call is FunctionPlan) {
    return 'target.${call.binding.callPath}${dartOpaqueTypeArguments(call.binding.typeParameters)}($arguments)';
  }
  final member = call as MemberCallPlan;
  final receiver = member.kind == MemberCallKind.constructor
      ? dartReferenceClassType(member.owner)
      : member.isStatic
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
