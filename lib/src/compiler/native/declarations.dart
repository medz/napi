import '../emit/typescript/declarations.dart'
    show
        emitMemberName,
        emitParameterVariants,
        emitReferenceInheritance,
        emitWriteOnlyReads,
        emitViewGetterResult,
        emitResult,
        emitTypeParameters,
        emitOpaquePhantom,
        emitFunctionDeclarations,
        emitPromiseResolutionDeclarations;
import '../ir/model.dart';
import '../emit/typescript/values.dart';
import 'plan.dart';

/// The same parameter/default/nullability shape used by the Wasm declarations.
String emitNativeDeclarations(NativeModulePlan plan) {
  final code = StringBuffer(
    '// Generated declarations for the native module.\n',
  );
  for (final declaration in emitPromiseResolutionDeclarations(
    plan.calls.where((call) => call.returnsFuture).map((call) => call.output),
  )) {
    code.writeln(declaration);
  }
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
    for (final declaration in emitFunctionDeclarations(
      function.exportName,
      function.parameters,
      function.inputs,
      function.output,
      function.function!.typeParameters,
      returnsFuture: function.returnsFuture,
      returnsStream: function.returnsStream,
      callable: function.parameters.any(
        (p) => p.kind != ParameterKind.requiredPositional,
      ),
    )) {
      code.writeln(declaration);
    }
  }
  for (final binding in plan.classes) {
    code.writeln(
      'export declare class ${binding.binding.exportName}${emitTypeParameters(binding.binding.typeParameters, invariant: true)} {',
    );
    if (binding.binding.typeParameters.isNotEmpty) {
      code.writeln('  ${emitOpaquePhantom(binding.binding.typeParameters)}');
    }
    code.writeln(
      '  private readonly \$napiReference${binding.shape.classId}: void;',
    );
    if (binding.hasPublicConstructor) {
      for (final parameters in emitParameterVariants(
        binding.constructor.parameters,
        binding.constructor.inputs,
      )) {
        code.writeln('  constructor($parameters);');
      }
    } else {
      code.writeln('  private constructor();');
    }
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
      final generics = call.member?.kind == MemberKind.constructor
          ? emitTypeParameters(binding.binding.typeParameters)
          : '';
      final result = emitResult(
        call.output,
        returnsFuture: call.returnsFuture,
        returnsStream: call.returnsStream,
      );
      for (final parameters in emitParameterVariants(
        call.parameters,
        call.inputs,
      )) {
        switch (call.kind) {
          case NativeCallKind.method:
            code.writeln('  $prefix$name$generics($parameters): $result;');
          case NativeCallKind.getter:
            code.writeln('  ${prefix}get $name(): $result;');
          case NativeCallKind.setter:
            code.writeln('  ${prefix}set $name($parameters);');
          default:
            throw StateError('Unsupported class declaration');
        }
      }
    }
    for (final declaration in emitWriteOnlyReads(
      binding.shape,
      plan.classes.map((binding) => binding.shape).toList(),
      (ref) {
        final member = plan.classes[ref.classId].members[ref.memberIndex];
        return emitViewGetterResult(
          member.output,
          returnsFuture: member.returnsFuture,
          returnsStream: member.returnsStream,
        );
      },
    )) {
      code.writeln(declaration);
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
