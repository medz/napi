import 'dart:convert';

import '../analysis/reference_views.dart' show hasCompositeReferenceViews;
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
        containsDictionary,
        containsValueClass;
import 'plan.dart';
import 'structural.dart';

String _quote(String value) => jsonEncode(value).replaceAll(r'$', r'\$');

/// Generate business-specific Dart only. The Node-API bridge stays generic.
String emitNativeDart(NativeModulePlan plan) {
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
  final structures = NativeStructuralEmitter();
  final code = StringBuffer();
  if (hasDictionary) {
    code.writeln("import 'dart:convert' show jsonEncode;");
    code.writeln("import 'package:napi/napi.dart' as napi;");
  }
  if (hasStructures) code.writeln("import 'dart:ffi';");
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
  if (plan.classes.isNotEmpty) {
    code.writeln('const _referenceMemberships = <Set<int>>[');
    for (final binding in plan.classes) {
      code.writeln('  {${binding.shape.memberships.join(', ')}},');
    }
    code.writeln('];');
    code.writeln('''int _referenceClass(Object value, String path) {
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
    final parameters = call.parameters;
    final positionalCount = parameters.where((p) => !_named(p)).length;
    final named = parameters.where(_named).toList();
    final capacity = positionalCount + (named.isEmpty ? 0 : 1);
    final rawStructuralArguments =
        call.function != null &&
        parameters.every((p) => p.kind == ParameterKind.requiredPositional) &&
        !call.inputs.any((value) => value is ReferenceConversion) &&
        call.output is! ReferenceConversion;
    code.writeln(
      'int ${call.callback}(int envAddress, int infoAddress) {\n  try {',
    );
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
    }
    if (named.isNotEmpty) {
      code.writeln(
        '    final options = _api.options(call, $positionalCount, ${jsonEncode(named.map((p) => p.name).toList())}, ${_quote('${call.context} options')});',
      );
    }
    final preflight =
        !rawStructuralArguments && call.inputs.any(containsValueClass);
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
        _readReference(code, conversion, index, 'reference$index');
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
        _readReference(code, conversion, index, 'a$index');
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
          '    a$index = $read(call.env, raw$index, _NativeReadState(), $path, 0);',
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
    if (call.isConstructor) {
      code.writeln(
        '    return _api.wrap(call, $invocation, ${call.classId}, ${_quote(call.context)});',
      );
    } else if (call.output == null) {
      code.writeln(
        '    $invocation;\n    return _api.undefinedResult(call.env);',
      );
    } else {
      final output = call.output!;
      code.writeln('    final value = $invocation;');
      if (output.nullable &&
          output is! ListConversion &&
          output is! RecordConversion &&
          output is! MapConversion &&
          output is! DictionaryConversion &&
          output is! ValueClassConversion) {
        code.writeln(
          '    if (value == null) return _api.nullResult(call.env);',
        );
      }
      if (output is ReferenceConversion) {
        code.writeln(
          '    return _api.referenceResult(call.env, value, ${output.classId}, ${_quote(output.context)});',
        );
      } else if (output is ScalarConversion) {
        final context = output.kind == ScalarKind.integer && !output.usesBigInt
            ? ', ${_quote(output.context)}'
            : '';
        code.writeln(
          '    return _api.${nativeScalarWriter(output)}(call.env, value$context);',
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
          '      return $write(call.env, value, state, ${_quote(output.context)}, 0);\n'
          '    } catch (_) {\n'
          '      _api.rollbackReferences(state.pending);\n'
          '      rethrow;\n'
          '    }',
        );
      } else {
        throw StateError('Unsupported native output conversion');
      }
    }
    code.writeln(
      '  } catch (error) {\n    return _api.fail(envAddress, error);\n  }\n}',
    );
  }
  if (hasStructures) {
    code.writeln(nativeStructuralPrelude);
    code.write(structures.source);
  }
  return code.toString();
}

void _readReference(
  StringBuffer code,
  ReferenceConversion conversion,
  int index,
  String destination,
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
  if (conversion.nullable) code.writeln('    }');
}

bool _named(ParameterBinding p) =>
    p.kind == ParameterKind.requiredNamed ||
    p.kind == ParameterKind.optionalNamed;
bool _optional(ParameterBinding p) =>
    p.kind == ParameterKind.optionalNamed ||
    p.kind == ParameterKind.optionalPositional;
