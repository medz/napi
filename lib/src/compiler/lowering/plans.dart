import '../ir/binding.dart';

enum ConversionDirection { jsToDart, dartToJs }

enum ConversionOperation {
  safeIntegerFromJs,
  safeIntegerToJs,
  doubleFromJs,
  doubleToJs,
  booleanFromJs,
  booleanToJs,
  stringFromJs,
  stringToJs,
  voidToJs,
}

/// Direction-specific executable conversion choice, produced only by lowering.
final class ConversionPlan {
  const ConversionPlan({
    required this.type,
    required this.direction,
    required this.operation,
  });

  final PrimitiveTypePolicy type;
  final ConversionDirection direction;
  final ConversionOperation operation;
}

enum LifetimeKind { synchronousValues }

/// No retention or cleanup is needed by the scalar-only foundation.
final class LifetimePlan {
  const LifetimePlan({this.kind = LifetimeKind.synchronousValues});

  final LifetimeKind kind;
}

final class CallPlan {
  CallPlan({
    required this.binding,
    required Iterable<ConversionPlan> arguments,
    required this.result,
    required this.lifetime,
  }) : arguments = List.unmodifiable(arguments);

  final FunctionBinding binding;
  final List<ConversionPlan> arguments;
  final ConversionPlan result;
  final LifetimePlan lifetime;

  int get requiredArgumentCount => arguments.length;
}

final class ModulePlan {
  ModulePlan({required this.sourceUri, required Iterable<CallPlan> calls})
    : calls = List.unmodifiable(calls);

  final Uri sourceUri;
  final List<CallPlan> calls;
}
