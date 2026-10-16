import 'dart:convert';

import '../../lowering/plan.dart';
import 'arguments.dart';
import 'structural.dart';

String emitBoundary(ModulePlan plan) {
  final conversions = plan.conversions;
  final policies = [
    for (final c in conversions)
      if (c is ScalarConversion) scalarPolicy(c) else null,
  ];
  final outputs = {for (final call in plan.calls) ?call.outputContext};
  final structures = {
    for (final (index, conversion) in conversions.indexed)
      if (conversion is ListConversion || conversion is RecordConversion)
        index: emitStructuralBoundary(
          conversion,
          prefix: 'structure$index',
          generateRead: !outputs.contains(index),
          generateWrite: outputs.contains(index),
        ),
  };
  return '''// Generated JS imports for the Wasm boundary, not a consumer entry.
const policies = ${jsonEncode(policies)};
function checkedScalar(value, policy, path) {
  if (value === null && policy.nullable) return null;
  if (typeof value !== policy.type) {
    throw new TypeError(path + ': expected a JavaScript ' + policy.type + (policy.nullable ? ' or null' : ''));
  }
  if (policy.integer) {
    if (policy.type === 'number' && !Number.isSafeInteger(value)) {
      throw new RangeError(path + ': expected a safe integer');
    }
    if (policy.type === 'bigint' && (value < -9223372036854775808n || value > 9223372036854775807n)) {
      throw new RangeError(path + ': expected a signed 64-bit Dart int');
    }
  }
  return value;
}
function checked(value, context) { return checkedScalar(value, policies[context], policies[context].context); }
export function readValue(value, context) {
  switch (context) {
${[for (final e in structures.entries)
    if (e.value.read != null) '    case ${e.key}: return ${e.value.read}(value, ${jsonEncode(conversions[e.key].context)}, {work: 0, active: new Set()}, 0);'].join('\n')}
    default: return checked(value, context);
  }
}
export function writeValue(value, context) {
  switch (context) {
${[for (final e in structures.entries)
    if (e.value.write != null) '    case ${e.key}: return ${e.value.write}(value, ${jsonEncode(conversions[e.key].context)}, {work: 0, active: new Set()}, 0);'].join('\n')}
    default: return checked(value, context);
  }
}
// Called only after checked() has established a primitive bigint. Decimal
// text avoids any precision-losing conversion through a JavaScript number.
export function readBigInt(value) { return value.toString(); }
export function writeBigInt(value, context) { return checked(BigInt(value), context); }
export function throwDartError(message) { throw new Error(message); }
${structures.isEmpty ? '' : structuralPolicy}
${structures.values.map((s) => s.source).join('\n')}
${plan.classes.isNotEmpty || plan.functions.any((f) => f.representation == ExportRepresentation.callableGlobal) ? argumentPolicy : ''}
''';
}
