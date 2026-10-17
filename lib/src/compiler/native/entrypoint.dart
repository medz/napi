import 'dart:convert';

import '../analysis/reference_views.dart' show hasCompositeReferenceViews;
import '../analysis/validate.dart' show resourcePolicies;
import '../emit/dart/entrypoint.dart' show renderDartDefault;
import '../ir/model.dart';
import '../lowering/plan.dart'
    show
        DictionaryConversion,
        ListConversion,
        MapConversion,
        RecordConversion,
        ReferenceConversion,
        ScalarConversion,
        ScalarKind,
        ValueClassConversion,
        ValueConversion,
        containsDictionary,
        containsValueClass,
        conversionGraph;
import 'plan.dart';
import 'structural.dart';

String _quote(String value) => jsonEncode(value).replaceAll(r'$', r'\$');

/// Generate business-specific Dart only. The Node-API bridge stays generic.
String emitNativeDart(NativeModulePlan plan) {
  final hasFutures = plan.calls.any((call) => call.returnsFuture);
  final policies = resourcePolicies([
    for (final binding in plan.classes) binding.shape,
  ]);
  final hasResources = policies.isNotEmpty;
  final hasCompositeViews = hasCompositeReferenceViews([
    for (final binding in plan.classes) binding.shape,
  ]);
  final hasStructures = plan.calls.any(
    (call) => [...call.inputs, if (call.output != null) call.output!].any(
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
  if (hasResources) code.writeln("import 'package:napi/runtime.dart';");
  if (hasDictionary) {
    code.writeln("import 'dart:convert' show jsonEncode;");
    code.writeln("import 'package:napi/napi.dart' as napi;");
  }
  if (hasStructures || hasFutures) {
    code.writeln("import 'dart:ffi';");
  }
  code.write('''
import 'package:napi/src/compiler/native/bindings.dart';
import ${_quote(plan.bindings.importUri.toString())} as target;

late final NapiApi _api;
@pragma('vm:entry-point')
List<Object?> napiBindings(int apiTableAddress, int tableCount) {
  _api = NapiApi(apiTableAddress, tableCount${plan.classes.isEmpty ? '' : ', referenceClass: _referenceClass, classMemberships: _referenceMemberships'}${hasCompositeViews ? ', referenceViews: _referenceViews' : ''});
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
  code.writeln('''  ];
}
@pragma('vm:entry-point')
void releaseOwner(int id) => _api.releaseOwner(id);
${hasFutures ? "@pragma('vm:entry-point')\nList<Object?>? releaseFuture(int token) => _api.releaseFuture(token);\n" : ''}void main() {}
''');
  if (plan.classes.isNotEmpty) {
    if (hasResources) {
      code.writeln('''ResourceControl? _resourceControl(Object value) {
  int? policy;''');
      for (final entry in policies.entries) {
        code.writeln(
          '''  if (value is target.${plan.classes[entry.key].binding.callPath}) {
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
    code.writeln('];');
    code.writeln('''int _referenceClass(Object value, String path) {
  ${hasResources ? '_resourceControl(value);' : ''}
  int? canonical;''');
    for (final index in plan.referenceClassOrder) {
      code.writeln(
        '''  if (value is target.${plan.classes[index].binding.callPath}) {
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
          '  if (value is target.${binding.binding.callPath}) ${binding.shape.classId},',
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
    final positionalCount = parameters.where((p) => !_named(p)).length;
    final named = parameters.where(_named).toList();
    final capacity = positionalCount + (named.isEmpty ? 0 : 1);
    final rawStructuralArguments =
        !retainsResources &&
        !call.returnsFuture &&
        call.function != null &&
        parameters.every((p) => p.kind == ParameterKind.requiredPositional) &&
        !call.inputs.any((value) => value is ReferenceConversion) &&
        call.output is! ReferenceConversion;
    code.writeln(
      'int ${call.callback}(int envAddress, int infoAddress${call.returnsFuture ? ', int token' : ''}) {\n${call.returnsFuture ? '  _api.beginFuture(token);\n' : ''}',
    );
    if (retainsResources && !call.isCleanup) {
      code.writeln('  final operation = ResourceOperation();');
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
        '    if (object is! target.${call.owner!.callPath}) throw NapiTypeError(${_quote('${call.context}: invalid native receiver')});',
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
            call.returnsFuture ||
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
          final defaulted = isNamed
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
          final value = isNamed
              ? '_api.requiredOption(call.env, options, $namedIndex, $path)'
              : '_api.requiredArgument(call, $index, $path)';
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
          : isNamed
          ? '_api.requiredOption(call.env, options, $option, $path)'
          : '_api.requiredArgument(call, $index, $path)';
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
    if (call.returnsFuture) {
      if (call.isCleanup) {
        code.writeln('''    final (promise, first) = _api.bindCleanupFuture(envAddress, token, control);
    if (!first) return promise;''');
      }
      code.writeln(
        '    _api.retainFuture(token, [${[if (call.owner != null && !call.isStatic) 'object', for (var i = 0; i < parameters.length; i++) 'a$i'].join(', ')}]${retainsResources && call.output != null && call.output is! ScalarConversion ? ', observeEnv: envAddress' : ''});',
      );
      code.writeln('    final env = Pointer<Void>.fromAddress(envAddress);');
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
      if (call.isConstructor) {
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
        '  } catch (error) {\n    return _api.fail(envAddress, error);\n  }${retainsResources ? ' finally {\n    operation.release();\n  }' : ''}\n}',
      );
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
      (output is ReferenceConversion || output is ScalarConversion)) {
    code.writeln('    if (value == null) return _api.nullResult($env);');
  }
  if (output is ReferenceConversion) {
    code.writeln(
      '    return _api.referenceResult($env, value, ${output.classId}, ${_quote(output.context)});',
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
    '    if (object$index is! target.${conversion.classBinding.callPath}) throw NapiTypeError(${_quote('${conversion.context}: expected ${conversion.classBinding.exportName}')});',
  );
  code.writeln('    $destination = object$index;');
  if (retainsResources) {
    code.writeln('    operation.retain(_resourceControl(object$index));');
  }
  if (conversion.nullable) code.writeln('    }');
}

bool _named(ParameterBinding p) =>
    p.kind == ParameterKind.requiredNamed ||
    p.kind == ParameterKind.optionalNamed;
bool _optional(ParameterBinding p) =>
    p.kind == ParameterKind.optionalNamed ||
    p.kind == ParameterKind.optionalPositional;
