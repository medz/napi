import '../../ir/binding.dart';
import '../../lowering/plans.dart';

String emitTypeScript(ModulePlan module) {
  final out = StringBuffer(
    '// Generated from the same lowered contracts as the runtime wrappers.\n',
  );
  for (final call in module.calls) {
    final arguments = <String>[];
    for (var i = 0; i < call.arguments.length; i++) {
      arguments.add('a$i: ${_type(call.arguments[i].type.kind)}');
    }
    out.writeln(
      'export declare function ${call.binding.publicName}(${arguments.join(', ')}): ${_type(call.result.type.kind)};',
    );
  }
  return out.toString();
}

String _type(PrimitiveKind kind) => switch (kind) {
  PrimitiveKind.integer || PrimitiveKind.doublePrecision => 'number',
  PrimitiveKind.boolean => 'boolean',
  PrimitiveKind.string => 'string',
  PrimitiveKind.voidType => 'void',
};
