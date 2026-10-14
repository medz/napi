import 'dart:convert';

import '../../lowering/plans.dart';

/// Each wrapper contains its own statically selected checks and invocation.
String emitJavaScript(ModulePlan module) {
  final out = StringBuffer(
    '''// Generated specialized facade; ready when ESM import resolves.
import { initialize } from './bootstrap.mjs';
import { unwrap } from './errors.mjs';
const api = await initialize();
''',
  );
  for (var index = 0; index < module.calls.length; index++) {
    final call = module.calls[index];
    final args = List.generate(call.arguments.length, (i) => 'a$i');
    out.writeln('function __napiCall$index(${args.join(', ')}) {');
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      final path =
          '${call.binding.publicName}.${call.binding.parameters[i].name}';
      final operation = call.arguments[i].operation;
      final jsType = switch (operation) {
        ConversionOperation.safeIntegerFromJs ||
        ConversionOperation.doubleFromJs => 'number',
        ConversionOperation.booleanFromJs => 'boolean',
        ConversionOperation.stringFromJs => 'string',
        _ => throw StateError('void parameter reached emission'),
      };
      out.writeln(
        '  if (typeof $arg !== "$jsType") throw new TypeError(${jsonEncode('$path must be a $jsType')});',
      );
      if (operation == ConversionOperation.safeIntegerFromJs) {
        out.writeln(
          '  if (!Number.isSafeInteger($arg)) throw new RangeError(${jsonEncode('$path must be a safe integer')});',
        );
      }
    }
    final invocation = 'unwrap(api.c$index(${args.join(', ')}))';
    out.writeln(
      call.result.operation == ConversionOperation.voidToJs
          ? '  $invocation;'
          : '  return $invocation;',
    );
    out.writeln('}');
    out.writeln('export { __napiCall$index as ${call.binding.publicName} };');
  }
  return out.toString();
}
