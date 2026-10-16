import '../emit/typescript/declarations.dart'
    show emitMemberName, emitParameters;
import '../ir/model.dart';
import 'plan.dart';

/// The same parameter/default/nullability shape used by the Wasm declarations.
String emitNativeDeclarations(NativeModulePlan plan) {
  final code = StringBuffer(
    '// Generated declarations for the native module.\n',
  );
  for (final function in plan.functions) {
    final parameters = emitParameters(function.parameters, function.inputs);
    final result = function.output?.typescriptType ?? 'void';
    if (function.parameters.any(
      (p) => p.kind != ParameterKind.requiredPositional,
    )) {
      code.writeln(
        'export declare const ${function.exportName}: ($parameters) => $result;',
      );
    } else {
      code.writeln(
        'export declare function ${function.exportName}($parameters): $result;',
      );
    }
  }
  for (final binding in plan.classes) {
    code.writeln('export declare class ${binding.binding.exportName} {');
    code.writeln(
      '  constructor(${emitParameters(binding.constructor.parameters, binding.constructor.inputs)});',
    );
    for (final call in binding.members) {
      final prefix = call.isStatic ? 'static ' : '';
      final name = emitMemberName(call.exportName);
      final parameters = emitParameters(call.parameters, call.inputs);
      final result = call.output?.typescriptType ?? 'void';
      switch (call.kind) {
        case NativeCallKind.method:
          code.writeln('  $prefix$name($parameters): $result;');
        case NativeCallKind.getter:
          code.writeln('  ${prefix}get $name(): $result;');
        case NativeCallKind.setter:
          code.writeln('  ${prefix}set $name($parameters);');
        default:
          throw StateError('Unsupported class declaration');
      }
    }
    code.writeln('}');
  }
  return code.toString();
}
