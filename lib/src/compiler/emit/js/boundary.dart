import 'dart:convert';

import '../../lowering/plan.dart';

String emitBoundary(ModulePlan plan) {
  final contexts = [
    for (final function in plan.functions) ...[
      ...function.inputs.map((input) => input.context),
      function.output.context,
    ],
  ];
  return '''// Generated JS imports for the Wasm boundary, not a consumer entry.
const contexts = ${jsonEncode(contexts)};
function checked(value, context) {
  if (typeof value !== 'number') {
    throw new TypeError(contexts[context] + ': expected a JavaScript number');
  }
  if (!Number.isSafeInteger(value)) {
    throw new RangeError(contexts[context] + ': expected a safe integer');
  }
  return value;
}
export function readInt(value, context) { return checked(value, context); }
export function writeInt(value, context) { return checked(value, context); }
export function throwDartError(message) { throw new Error(message); }
''';
}
