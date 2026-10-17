import '../emit/typescript/declarations.dart'
    show emitMemberName, emitParameters, emitReferenceInheritance, emitResult;
import '../ir/model.dart';
import '../emit/typescript/values.dart';
import 'plan.dart';

/// The same parameter/default/nullability shape used by the Wasm declarations.
String emitNativeDeclarations(NativeModulePlan plan) {
  final code = StringBuffer(
    '// Generated declarations for the native module.\n',
  );
  code.writeln(
    emitValueDeclarations(
      plan.bindings.classes,
      plan.valueSchemas,
      [
        for (final call in plan.calls) ...[...call.inputs, ?call.output],
      ],
      reservedNames: {for (final f in plan.functions) f.exportName},
    ),
  );
  for (final function in plan.functions) {
    final parameters = emitParameters(function.parameters, function.inputs);
    final result = emitResult(
      function.output,
      returnsFuture: function.returnsFuture,
    );
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
      binding.hasPublicConstructor
          ? '  constructor(${emitParameters(binding.constructor.parameters, binding.constructor.inputs)});'
          : '  private constructor();',
    );
    for (final call in [
      ...binding.members.where((call) => call.isStatic),
      for (final property in binding.shape.prototypeProperties)
        for (final ref in [
          ?property.method,
          ?property.getter,
          ?property.setter,
        ])
          plan.classes[ref.classId].members[ref.memberIndex],
    ]) {
      final prefix = call.isStatic ? 'static ' : '';
      final name = emitMemberName(call.exportName);
      final parameters = emitParameters(call.parameters, call.inputs);
      final result = emitResult(call.output, returnsFuture: call.returnsFuture);
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
    for (final declaration in emitReferenceInheritance(
      binding.shape,
      plan.classes.map((binding) => binding.shape).toList(),
    )) {
      code.writeln(declaration);
    }
  }
  return code.toString();
}
