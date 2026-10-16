import 'dart:convert';

import '../../lowering/plan.dart';

String emitBoundary(ModulePlan plan) {
  final conversions = [
    for (final function in plan.functions) ...[
      ...function.inputs,
      function.output,
    ],
  ];
  final policies = [
    for (final c in conversions)
      {
        'context': c.context,
        'type': c.jsType,
        'nullable': c.nullable,
        'integer': c.kind == ScalarKind.integer,
      },
  ];
  return '''// Generated JS imports for the Wasm boundary, not a consumer entry.
const policies = ${jsonEncode(policies)};
function checked(value, context) {
  const policy = policies[context];
  if (value === null && policy.nullable) return null;
  if (typeof value !== policy.type) {
    throw new TypeError(policy.context + ': expected a JavaScript ' + policy.type + (policy.nullable ? ' or null' : ''));
  }
  if (policy.integer) {
    if (policy.type === 'number' && !Number.isSafeInteger(value)) {
      throw new RangeError(policy.context + ': expected a safe integer');
    }
    if (policy.type === 'bigint' && (value < -9223372036854775808n || value > 9223372036854775807n)) {
      throw new RangeError(policy.context + ': expected a signed 64-bit Dart int');
    }
  }
  return value;
}
export function readValue(value, context) { return checked(value, context); }
export function writeValue(value, context) { return checked(value, context); }
// Called only after checked() has established a primitive bigint. Decimal
// text avoids any precision-losing conversion through a JavaScript number.
export function readBigInt(value) { return value.toString(); }
export function writeBigInt(value, context) { return checked(BigInt(value), context); }
export function throwDartError(message) { throw new Error(message); }
''';
}
