import 'dart:convert';

import '../analysis/reference_views.dart' show hasCompositeReferenceViews;
import '../analysis/validate.dart' show resourcePolicies;
import '../emit/dart/entrypoint.dart' show renderDartDefault;
import '../ir/model.dart';
import '../lowering/plan.dart'
    show
        AbortSignalConversion,
        BinaryConversion,
        CallbackConversion,
        DictionaryConversion,
        ListConversion,
        MapConversion,
        OpaqueConversion,
        RecordConversion,
        ReferenceConversion,
        ScalarConversion,
        ScalarKind,
        SharedBytesConversion,
        ValueClassConversion,
        ValueConversion,
        containsDictionary,
        containsValueClass,
        conversionGraph,
        dartOpaqueTypeArguments,
        dartReferenceClassType,
        dartReferenceClassTest;
import 'plan.dart';
import 'structural.dart';

String _quote(String value) => jsonEncode(value).replaceAll(r'$', r'\$');

/// Generate business-specific Dart only. The Node-API bridge stays generic.
String emitNativeDart(NativeModulePlan plan) {
  final hasStreams = plan.hasStreams;
  final hasBinary = plan.hasBinary;
  final hasSharedBytesTypes = plan.hasSharedBytesTypes;
  final hasFutures = hasStreams || plan.calls.any((call) => call.returnsFuture);
  final hasCallbacks = plan.calls.any(
    (call) => call.inputs.any((value) => value is CallbackConversion),
  );
  final hasAsyncCallbacks = plan.calls.any(
    (call) => call.inputs.any(
      (value) => value is CallbackConversion && value.returnsFuture,
    ),
  );
  final hasSignals = plan.calls.any(
    (call) => call.inputs.any((value) => value is AbortSignalConversion),
  );
  final hasOpaque =
      plan.classes.any(
        (binding) => binding.binding.typeParameters.any((type) => type.opaque),
      ) ||
      plan.functions.any(
        (call) => call.function!.typeParameters.any((type) => type.opaque),
      );
  final policies = resourcePolicies([
    for (final binding in plan.classes) binding.shape,
  ]);
  final hasResources = policies.isNotEmpty;
  final hasCompositeViews = hasCompositeReferenceViews([
    for (final binding in plan.classes) binding.shape,
  ]);
  final hasStructures = plan.calls.any(
    (call) =>
        conversionGraph([...call.inputs, if (call.output != null) call.output!])
            .any(
              (value) =>
                  value is ListConversion ||
                  value is RecordConversion ||
                  value is MapConversion ||
                  value is DictionaryConversion ||
                  value is ValueClassConversion,
            ),
  );
  final hasDictionary = plan.calls.any(
    (call) => [
      ...call.inputs,
      if (call.output != null) call.output!,
    ].any(containsDictionary),
  );
  final structures = NativeStructuralEmitter(hasResources: hasResources);
  final code = StringBuffer();
  if (hasBinary) {
    code.writeln("import 'dart:typed_data' as typed_data;");
  }
  code.writeln("import 'package:napi/runtime.dart';");
  if (hasDictionary) {
    code.writeln("import 'dart:convert' show jsonEncode;");
  }
  if (hasDictionary || hasSignals || hasSharedBytesTypes) {
    code.writeln("import 'package:napi/napi.dart' as napi;");
  }
  if (hasStructures ||
      hasFutures ||
      hasOpaque ||
      hasCallbacks ||
      hasSignals ||
      hasBinary ||
      hasSharedBytesTypes) {
    code.writeln("import 'dart:ffi';");
  }
  code.write('''
import 'package:napi/src/compiler/native/bindings.dart';
import ${_quote(plan.bindings.importUri.toString())} as target;

${hasOpaque ? 'typedef _NapiHostValue = NativeHostValue;\n\n' : ''}late final NapiApi _api;
@pragma('vm:entry-point')
List<Object?> napiBindings(int apiTableAddress, int tableCount) {
  _api = NapiApi(apiTableAddress, tableCount${plan.classes.isEmpty && !hasStreams ? '' : ', referenceClass: _referenceClass, classMemberships: _referenceMemberships'}${hasCompositeViews ? ', referenceViews: _referenceViews' : ''});
  installSharedBytesAllocator(_api.allocateSharedBytes);
  return [
''');
  for (final function in plan.functions) {
    code.writeln(
      "    ['function', ${_quote(function.function!.exportName)}, ${function.callback}, ${function.javascriptArity}${function.returnsFuture ? ', true' : ''}],",
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
        '      [${_quote(metadataKind)}, ${_quote(member.exportName)}, ${member.callback}, ${member.javascriptArity}${member.returnsFuture ? ', true' : ''}],',
      );
    }
    code.writeln('    ], ${binding.constructor.javascriptArity}],');
  }
  if (hasStreams) {
    code.writeln(
      "    ['class', ${_quote(plan.streamClassName)}, _streamConstructor, ["
      "['method', 'next', _streamNext, 0, true], "
      "['method', 'return', _streamReturn, 0, true]], 0],",
    );
  }
  code.writeln('''  ];
}
@pragma('vm:entry-point')
void releaseOwner(int id) => _api.releaseOwner(id);
${hasFutures ? "@pragma('vm:entry-point')\nList<Object?>? releaseFuture(int token) => _api.releaseFuture(token);\n" : ''}${hasAsyncCallbacks || hasSignals ? "@pragma('vm:entry-point')\nObject? acceptCallback(int env, int token, bool rejected, int value) => _api.acceptCallback(env, token, rejected, value);\n" : ''}void main() {}
''');
  if (plan.classes.isNotEmpty || hasStreams) {
    if (hasResources) {
      code.writeln('''ResourceControl? _resourceControl(Object value) {
  int? policy;''');
      for (final entry in policies.entries) {
        code.writeln(
          '''  if (${dartReferenceClassTest(plan.classes[entry.key].binding, plan.classes.map((c) => c.binding), object: 'value')}) {
    if (policy != null && policy != ${entry.value}) throw NapiTypeError('Resource has incompatible cleanup policies');
    policy = ${entry.value};
  }''',
        );
      }
      code.writeln(
        '''  return policy == null ? null : ResourceControl.forObject(value);
}''',
      );
    }
    code.writeln('const _referenceMemberships = <Set<int>>[');
    for (final binding in plan.classes) {
      code.writeln('  {${binding.shape.memberships.join(', ')}},');
    }
    if (hasStreams) code.writeln('  {${plan.streamClassId}},');
    code.writeln('];');
    code.writeln('''int _referenceClass(Object value, String path) {
  ${hasStreams ? 'if (value is NapiStream<dynamic, NativeHostValue>) return ${plan.streamClassId};' : ''}
  ${hasResources ? '_resourceControl(value);' : ''}
  int? canonical;''');
    for (final index in plan.referenceClassOrder) {
      code.writeln(
        '''  if (${dartReferenceClassTest(plan.classes[index].binding, plan.classes.map((c) => c.binding), object: 'value')}) {
    if (canonical == null) { canonical = $index; }
    else if (!_referenceMemberships[canonical].contains($index)) {
      return -1;
    }
  }''',
      );
    }
    code.writeln('''  if (canonical == null) throw NapiTypeError('\$path: no unique most-specific selected class');
  return canonical;
}''');
    if (hasCompositeViews) {
      code.writeln('List<int> _referenceViews(Object value) => [');
      for (final binding in plan.classes) {
        code.writeln(
          '  if (${dartReferenceClassTest(binding.binding, plan.classes.map((c) => c.binding), object: 'value')}) ${binding.shape.classId},',
        );
      }
      code.writeln('];');
    }
  }
  for (final call in plan.calls) {
    final hasReceiver =
        call.owner != null && !call.isConstructor && !call.isStatic;
    final retainsResources =
        hasResources &&
        (hasReceiver ||
            conversionGraph(call.inputs)
                .any((value) => value is ReferenceConversion));
    final parameters = call.parameters;
    final hasOpaqueInputs = call.inputs.any(
      (value) => value is OpaqueConversion,
    );
    final hasCallbackInputs = call.inputs.any(
      (value) => value is CallbackConversion,
    );
    final hasSignalInputs = call.inputs.any(
      (value) => value is AbortSignalConversion,
    );
    final positionalCount = parameters.where((p) => !_named(p)).length;
    final named = parameters.where(_named).toList();
    final capacity = positionalCount + (named.isEmpty ? 0 : 1);
    final rawStructuralArguments =
        !retainsResources &&
        !hasOpaqueInputs &&
        !hasCallbackInputs &&
        !hasSignalInputs &&
        !call.returnsFuture &&
        !call.returnsStream &&
        call.function != null &&
        parameters.every((p) => p.kind == ParameterKind.requiredPositional) &&
        !call.inputs.any((value) => value is ReferenceConversion) &&
        call.output is! ReferenceConversion;
    code.writeln(
      'int ${call.callback}(int envAddress, int infoAddress${call.returnsFuture ? ', int token' : ''}) {\n${call.returnsFuture ? '  _api.beginFuture(token);\n' : ''}',
    );
    if (retainsResources && !call.isCleanup) {
      code.writeln('  final operation = ResourceOperation();');
      if (call.returnsStream) {
        code.writeln('  var operationTransferred = false;');
      }
      if (call.returnsFuture) {
        code.writeln('  _api.attachOperation(token, operation);');
      }
    }
    code.writeln('  try {');
    code.writeln(
      '    final call = _api.call(envAddress, infoAddress, $capacity);',
    );
    code.writeln(
      '    _api.checkNew(call, ${call.isConstructor}, ${_quote(call.context)});',
    );
    if (call.isConstructor && call.member == null) {
      code.writeln(
        '    throw NapiTypeError(${_quote('${call.context}: no selected public unnamed constructor')});',
      );
      code.writeln(
        '  } catch (error) {\n    return _api.fail(envAddress, error);\n  }\n}',
      );
      continue;
    }
    if (call.owner != null && !call.isConstructor && !call.isStatic) {
      code.writeln(
        '    final object = _api.ownerValue(call.env, call.self, ${_quote(call.context)}, ${call.classId});',
      );
      code.writeln(
        '    if (object is! ${dartReferenceClassType(call.owner!)}) throw NapiTypeError(${_quote('${call.context}: invalid native receiver')});',
      );
      if (call.isCleanup) {
        code.writeln('''    final control = _resourceControl(object)!;
    final operation = ResourceOperation(exempt: control);
    _api.attachOperation(token, operation);''');
      } else if (retainsResources) {
        code.writeln('    operation.retain(_resourceControl(object));');
      }
    }
    if (named.isNotEmpty) {
      code.writeln(
        '    final options = _api.options(call, $positionalCount, ${jsonEncode(named.map((p) => p.name).toList())}, ${_quote('${call.context} options')});',
      );
    }
    final preflight =
        !rawStructuralArguments &&
        (retainsResources ||
            hasOpaqueInputs ||
            hasCallbackInputs ||
            hasSignalInputs ||
            call.returnsFuture ||
            call.returnsStream ||
            call.inputs.any(containsValueClass));
    if (preflight) {
      var option = 0;
      for (final (index, parameter) in parameters.indexed) {
        final conversion = call.inputs[index];
        final path = _quote(conversion.context);
        final isNamed = _named(parameter);
        final namedIndex = option;
        if (isNamed) option++;
        if (_optional(parameter)) {
          final defaulted =
              parameter.presence == ParameterPresence.opaqueOptional
              ? isNamed
                    ? '!options.present[$namedIndex]'
                    : '$index >= call.argumentCount'
              : isNamed
              ? '_api.defaultOption(call.env, options, $namedIndex)'
              : '_api.omittedOrUndefined(call, $index)';
          final value = isNamed
              ? 'options.values[$namedIndex]'
              : 'call.arguments[$index]';
          code.writeln('    final default$index = $defaulted;');
          code.writeln(
            '    final raw$index = default$index ? nullptr : $value;',
          );
        } else {
          final value = _requiredValue(parameter, index, namedIndex, path);
          code.writeln('    final raw$index = $value;');
        }
      }
      // Callable Wasm globals finish presence, then unwrap all direct refs,
      // before their core performs any per-parameter value construction.
      for (final (index, parameter) in parameters.indexed) {
        final conversion = call.inputs[index];
        if (conversion is! ReferenceConversion) continue;
        code.writeln('    final ${conversion.dartType} reference$index;');
        if (_optional(parameter)) {
          code.writeln(
            '    if (default$index) {\n      reference$index = ${renderDartDefault(parameter, conversion)};\n    } else {',
          );
        }
        _readReference(
          code,
          conversion,
          index,
          'reference$index',
          retainsResources,
        );
        if (_optional(parameter)) code.writeln('    }');
      }
      for (final (index, parameter) in parameters.indexed) {
        final conversion = call.inputs[index];
        if (conversion is! CallbackConversion) continue;
        final skipped = [
          if (_optional(parameter)) 'default$index',
          if (conversion.nullable) '_api.isNull(call.env, raw$index)',
        ].join(' || ');
        code.writeln(
          '    ${skipped.isEmpty ? '' : 'if (!($skipped)) '}_api.checkCallback(call.env, raw$index, ${_quote(conversion.context)});',
        );
      }
    }
    var namedIndex = 0;
    for (final (index, parameter) in parameters.indexed) {
      final conversion = call.inputs[index];
      final path = _quote(conversion.context);
      final isNamed = _named(parameter);
      final option = namedIndex;
      if (isNamed) namedIndex++;
      final structural =
          conversion is ListConversion ||
          conversion is RecordConversion ||
          conversion is MapConversion ||
          conversion is DictionaryConversion ||
          conversion is ValueClassConversion;
      const undefined =
          'Pointer<Void>.fromAddress(_api.undefinedResult(call.env))';
      final raw = structural && rawStructuralArguments
          ? '(call.argumentCount > $index ? call.arguments[$index] : $undefined)'
          : _requiredValue(parameter, index, option, path);
      if (preflight && conversion is ReferenceConversion) {
        code.writeln(
          '    final ${conversion.dartType} a$index = reference$index;',
        );
        continue;
      }
      code.writeln('    final ${conversion.dartType} a$index;');
      if (_optional(parameter)) {
        final defaulted = preflight
            ? 'default$index'
            : parameter.presence == ParameterPresence.opaqueOptional
            ? isNamed
                  ? '!options.present[$option]'
                  : '$index >= call.argumentCount'
            : isNamed
            ? '_api.defaultOption(call.env, options, $option)'
            : '_api.omittedOrUndefined(call, $index)';
        code.writeln(
          '    if ($defaulted) {\n      a$index = ${renderDartDefault(parameter, conversion)};\n    } else {',
        );
      }
      if (!preflight) code.writeln('    final raw$index = $raw;');
      if (conversion is ReferenceConversion) {
        _readReference(code, conversion, index, 'a$index', retainsResources);
      } else if (conversion is OpaqueConversion) {
        code.writeln('    a$index = _api.ownHostValue(call.env, raw$index);');
      } else if (conversion is CallbackConversion) {
        _readCallback(code, conversion, index, structures, hasResources);
      } else if (conversion is AbortSignalConversion) {
        code.writeln(
          '    a$index = ${conversion.nullable ? '_api.isNull(call.env, raw$index) ? null : ' : ''}_api.abortSignal(call.env, raw$index, $path);',
        );
      } else if (conversion is BinaryConversion) {
        code.writeln(
          '    a$index = _api.binary(call.env, raw$index, ${conversion.kind.index}, $path${conversion.nullable ? ', nullable: true' : ''}) as ${conversion.dartType};',
        );
      } else if (conversion is SharedBytesConversion) {
        code.writeln(
          '    a$index = ${conversion.nullable ? '_api.isNull(call.env, raw$index) ? null : ' : ''}_api.sharedBytes(call.env, raw$index, $path);',
        );
      } else if (conversion is ScalarConversion) {
        final converted =
            '_api.${nativeScalarReader(conversion)}(call.env, raw$index, $path)';
        code.writeln(
          '    a$index = ${conversion.nullable ? '_api.isNull(call.env, raw$index) ? null : ' : ''}$converted;',
        );
      } else if (conversion is ListConversion ||
          conversion is RecordConversion ||
          conversion is MapConversion ||
          conversion is DictionaryConversion ||
          conversion is ValueClassConversion) {
        final read = structures.read(conversion);
        code.writeln(
          '    a$index = $read(call.env, raw$index, _NativeReadState(${hasResources
              ? retainsResources
                    ? 'operation'
                    : 'null'
              : ''}), $path, 0);',
        );
      } else {
        throw StateError('Unsupported native input conversion');
      }
      if (_optional(parameter)) code.writeln('    }');
    }
    final arguments = [
      for (final (index, parameter) in parameters.indexed)
        '${_named(parameter) ? '${parameter.name}: ' : ''}a$index',
    ].join(', ');
    final receiver = call.owner == null
        ? 'target'
        : call.member?.kind == MemberKind.constructor || call.isConstructor
        ? dartReferenceClassType(call.owner!)
        : call.isStatic
        ? 'target.${call.owner!.callPath}'
        : 'object';
    final path =
        call.function?.callPath ??
        call.member?.callPath ??
        call.member?.declaration.name;
    final invocation = switch (call.kind) {
      NativeCallKind.function =>
        'target.$path${dartOpaqueTypeArguments(call.function!.typeParameters)}($arguments)',
      NativeCallKind.constructor => '$receiver($arguments)',
      NativeCallKind.method => '$receiver.$path($arguments)',
      NativeCallKind.getter => '$receiver.$path',
      NativeCallKind.setter => '$receiver.$path = a0',
    };
    if (call.returnsFuture) {
      if (call.isCleanup) {
        if (hasSignalInputs) {
          code.writeln('    if (control.state == ResourceState.open) {');
          _checkSignals(code, call);
          code.writeln('    }');
        }
        code.writeln('''    final (promise, first) = _api.bindCleanupFuture(envAddress, token, control);
    if (!first) return promise;''');
      }
      code.writeln(
        '    _api.retainFuture(token, [${[if (call.owner != null && !call.isStatic) 'object', for (var i = 0; i < parameters.length; i++) 'a$i'].join(', ')}]${retainsResources && call.output != null && call.output is! ScalarConversion ? ', observeEnv: envAddress' : ''});',
      );
      code.writeln('    final env = Pointer<Void>.fromAddress(envAddress);');
      if (!call.isCleanup) _checkSignals(code, call);
      code.writeln(
        '    _api.completeFuture(envAddress, token, ${call.isCleanup ? 'control.dispose(() => $invocation)' : invocation}, (value) {',
      );
      _writeResult(code, call.output, structures, 'env');
      code.writeln('    }, ${_quote(call.context)});\n    return 0;');
      code.writeln(
        '  } catch (error, stack) {\n'
        '    _api.rejectFuture(envAddress, token, error, stack, ${_quote(call.context)});\n'
        '    return 0;\n  }\n}',
      );
    } else {
      _checkSignals(code, call);
      if (call.returnsStream) {
        code.writeln('    final stream = $invocation;');
        code.writeln('    final streamEnv = call.env;');
        code.writeln(
          '    final state = NapiStream<${call.output?.dartType ?? 'void'}, NativeHostValue>(stream, snapshot: (value) => _api.snapshotStreamValue(streamEnv, () {',
        );
        _writeResult(code, call.output, structures, 'streamEnv');
        code.writeln(
          '    }), releaseSnapshot: (value) => value.release(), roots: [${[if (hasReceiver) 'object', for (var i = 0; i < parameters.length; i++) 'a$i'].join(', ')}]${retainsResources ? ', operation: operation' : ''}${hasSignalInputs ? ', signals: [${[for (final (i, input) in call.inputs.indexed)
                  if (input is AbortSignalConversion) '${input.nullable ? 'if (a$i != null) ' : ''}a$i'].join(', ')}]' : ''});',
        );
        if (retainsResources) {
          code.writeln('    operationTransferred = true;');
        }
        code.writeln(
          '    var published = false;\n'
          '    try {\n'
          '      final result = _api.referenceResult(streamEnv, state, ${plan.streamClassId}, ${_quote(call.context)});\n'
          '      published = true;\n'
          '      return result;\n'
          '    } finally { state.finishCreation(published); }',
        );
      } else if (call.isConstructor) {
        code.writeln(
          '    return _api.wrap(call, $invocation, ${call.classId}, ${_quote(call.context)});',
        );
      } else {
        code.writeln(
          call.output == null
              ? '    $invocation;'
              : '    final value = $invocation;',
        );
        _writeResult(code, call.output, structures, 'call.env');
      }
      code.writeln(
        '  } catch (error) {\n    return _api.fail(envAddress, error);\n  }${retainsResources ? ' finally {\n    ${call.returnsStream ? 'if (!operationTransferred) ' : ''}operation.release();\n  }' : ''}\n}',
      );
    }
  }
  if (hasStreams) {
    code.writeln(
      "int _streamConstructor(int env, int info) => _api.fail(env, NapiTypeError('Stream iterator is not a public constructor'));",
    );
    for (final (name, method) in [
      ('_streamNext', 'next'),
      ('_streamReturn', 'return_'),
    ]) {
      code.writeln("""int $name(int envAddress, int infoAddress, int token) {
  _api.beginFuture(token);
  try {
    final call = _api.call(envAddress, infoAddress, 0);
    _api.checkNew(call, false, 'Stream iterator');
    final object = _api.ownerValue(call.env, call.self, 'Stream iterator', ${plan.streamClassId});
    if (object is! NapiStream<dynamic, NativeHostValue>) throw NapiTypeError('Stream iterator: invalid receiver');
    _api.retainFuture(token, [object, ...object.retainedInputs]);
    final env = call.env;
    _api.completeFuture<StreamDelivery<NativeHostValue>>(envAddress, token, object.$method(), (delivery) {
      _api.attachOperation(token, delivery);
      if (delivery.kind == StreamDeliveryKind.error) {
        final error = delivery.error!;
        Error.throwWithStackTrace(error is StreamBufferOverflow ? NapiRangeError(error.message.toString()) : error, delivery.stack!);
      }
      return _api.iteratorResult(env, delivery.value, done: delivery.kind == StreamDeliveryKind.done);
    }, 'Stream iterator', onFailure: (delivery, error, stack) {
      if (delivery.kind != StreamDeliveryKind.error) object.deliveryFailed(error, stack);
    });
    return 0;
  } catch (error, stack) {
    _api.rejectFuture(envAddress, token, error, stack, 'Stream iterator');
    return 0;
  }
}
""");
    }
  }
  if (hasStructures) {
    code.writeln(
      hasResources
          ? nativeStructuralPrelude.replaceFirst(
              'final class _NativeReadState {',
              '''final class _NativeReadState {
  _NativeReadState(this.operation);
  final ResourceOperation? operation;''',
            )
          : nativeStructuralPrelude,
    );
    code.write(structures.source);
  }
  return code.toString();
}

void _checkSignals(StringBuffer code, NativeCallPlan call) {
  for (final (index, input) in call.inputs.indexed) {
    if (input is AbortSignalConversion) {
      code.writeln('    a$index${input.nullable ? '?' : ''}.throwIfAborted();');
    }
  }
}

void _readCallback(
  StringBuffer code,
  CallbackConversion conversion,
  int index,
  NativeStructuralEmitter structures,
  bool hasResources,
) {
  if (conversion.nullable) {
    code.writeln(
      '    if (_api.isNull(call.env, raw$index)) { a$index = null; } else {',
    );
  }
  final parameters = [
    for (final (i, input) in conversion.inputs.indexed) '${input.dartType} c$i',
  ].join(', ');
  final type = conversion.nullable
      ? conversion.dartType.substring(0, conversion.dartType.length - 1)
      : conversion.dartType;
  code.writeln(
    '    a$index = _api.callback<$type>(call.env, raw$index, ${_quote(conversion.signatureKey)}, ${_quote(conversion.context)}, (callback) ${conversion.returnsFuture ? '{\n      late final $type adapter;\n      adapter =' : '=>'} ($parameters) {',
  );
  code.writeln(
    "      return callback.${conversion.returnsFuture ? 'invokeFuture' : 'invoke'}<${conversion.output?.dartType ?? 'void'}>(${conversion.returnsFuture ? 'adapter, ' : ''}${conversion.inputs.length}, (env, argv) {",
  );
  for (final (i, input) in conversion.inputs.indexed) {
    if (input is ScalarConversion) continue;
    code.writeln(
      '        final snapshot$i = ${structures.snapshotOutput(input)}(c$i, _NativeWriteState(), ${_quote(input.context)}, 0);',
    );
  }
  for (final (i, input) in conversion.inputs.indexed) {
    final String value;
    if (input is ScalarConversion) {
      final context = input.kind == ScalarKind.integer && !input.usesBigInt
          ? ', ${_quote(input.context)}'
          : '';
      value =
          '${input.nullable ? 'c$i == null ? _api.nullResult(env) : ' : ''}'
          '_api.${nativeScalarWriter(input)}(env, c$i$context)';
    } else {
      value =
          '${structures.writeSnapshot(input)}(env, snapshot$i, _NativeWriteState(), ${_quote(input.context)})';
    }
    code.writeln('        argv[$i] = Pointer<Void>.fromAddress($value);');
  }
  code.writeln('      }, (env, result) {');
  final output = conversion.output;
  if (output is ScalarConversion) {
    code.writeln(
      '        return ${output.nullable ? '_api.isNull(env, result) ? null : ' : ''}'
      '_api.${nativeScalarReader(output)}(env, result, ${_quote(output.context)});',
    );
  } else if (output != null) {
    code.writeln(
      '        return ${structures.read(output)}(env, result, _NativeReadState(${hasResources ? 'null' : ''}), ${_quote(output.context)}, 0);',
    );
  }
  code.writeln('      });');
  if (conversion.returnsFuture) code.writeln('      };\n      return adapter;');
  code.writeln('    }, prechecked: true);');
  if (conversion.nullable) code.writeln('    }');
}

void _writeResult(
  StringBuffer code,
  ValueConversion? output,
  NativeStructuralEmitter structures,
  String env,
) {
  if (output == null) {
    code.writeln('    return _api.undefinedResult($env);');
    return;
  }
  if (output.nullable &&
      (output is ReferenceConversion ||
          output is ScalarConversion ||
          output is BinaryConversion ||
          output is SharedBytesConversion ||
          output is OpaqueConversion)) {
    code.writeln('    if (value == null) return _api.nullResult($env);');
  }
  if (output is ReferenceConversion) {
    code.writeln(
      '    return _api.referenceResult($env, value, ${output.classId}, ${_quote(output.context)});',
    );
  } else if (output is OpaqueConversion) {
    code.writeln('    return _api.hostValue($env, value).address;');
  } else if (output is BinaryConversion) {
    code.writeln(
      '    return _api.binaryResult($env, value, ${output.kind.index}, ${_quote(output.context)});',
    );
  } else if (output is SharedBytesConversion) {
    code.writeln(
      '    return _api.sharedBytesResult($env, value, ${_quote(output.context)});',
    );
  } else if (output is ScalarConversion) {
    final context = output.kind == ScalarKind.integer && !output.usesBigInt
        ? ', ${_quote(output.context)}'
        : '';
    code.writeln(
      '    return _api.${nativeScalarWriter(output)}($env, value$context);',
    );
  } else if (output is ListConversion ||
      output is RecordConversion ||
      output is MapConversion ||
      output is DictionaryConversion ||
      output is ValueClassConversion) {
    final write = structures.write(output);
    code.writeln(
      '    final state = _NativeWriteState();\n'
      '    try {\n'
      '      return $write($env, value, state, ${_quote(output.context)}, 0);\n'
      '    } catch (_) {\n'
      '      _api.rollbackReferences(state.pending);\n'
      '      rethrow;\n'
      '    }',
    );
  } else {
    throw StateError('Unsupported native output conversion');
  }
}

void _readReference(
  StringBuffer code,
  ReferenceConversion conversion,
  int index,
  String destination,
  bool retainsResources,
) {
  if (conversion.nullable) {
    code.writeln(
      '    if (_api.isNull(call.env, raw$index)) {\n      $destination = null;\n    } else {',
    );
  }
  code.writeln(
    '    final object$index = _api.ownerValue(call.env, raw$index, ${_quote(conversion.context)}, ${conversion.classId});',
  );
  code.writeln(
    '    if (object$index is! ${dartReferenceClassType(conversion.classBinding)}) throw NapiTypeError(${_quote('${conversion.context}: expected ${conversion.classBinding.exportName}')});',
  );
  code.writeln('    $destination = object$index;');
  if (retainsResources) {
    code.writeln('    operation.retain(_resourceControl(object$index));');
  }
  if (conversion.nullable) code.writeln('    }');
}

String _requiredValue(
  ParameterBinding parameter,
  int index,
  int option,
  String path,
) {
  final opaque =
      parameter.presence == ParameterPresence.opaqueRequired ||
      parameter.presence == ParameterPresence.opaqueOptional;
  if (_named(parameter)) {
    return opaque
        ? '_api.presentOption(options, $option, $path)'
        : '_api.requiredOption(call.env, options, $option, $path)';
  }
  return opaque
      ? '_api.presentArgument(call, $index, $path)'
      : '_api.requiredArgument(call, $index, $path)';
}

bool _named(ParameterBinding p) =>
    p.kind == ParameterKind.requiredNamed ||
    p.kind == ParameterKind.optionalNamed;
bool _optional(ParameterBinding p) =>
    p.kind == ParameterKind.optionalNamed ||
    p.kind == ParameterKind.optionalPositional;
