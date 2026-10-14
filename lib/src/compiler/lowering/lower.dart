import '../analysis/validate.dart';
import '../ir/binding.dart';
import 'plans.dart';

ModulePlan lowerModule(BindingModule module) {
  validateModule(module);
  return ModulePlan(
    sourceUri: module.sourceUri,
    calls: module.functions.map(
      (binding) => CallPlan(
        binding: binding,
        arguments: binding.parameters.map(
          (parameter) => ConversionPlan(
            type: parameter.type,
            direction: ConversionDirection.jsToDart,
            operation: _operation(parameter.type.kind, input: true),
          ),
        ),
        result: ConversionPlan(
          type: binding.returnType,
          direction: ConversionDirection.dartToJs,
          operation: _operation(binding.returnType.kind, input: false),
        ),
        lifetime: const LifetimePlan(),
      ),
    ),
  );
}

ConversionOperation _operation(
  PrimitiveKind kind, {
  required bool input,
}) => switch (kind) {
  PrimitiveKind.integer =>
    input
        ? ConversionOperation.safeIntegerFromJs
        : ConversionOperation.safeIntegerToJs,
  PrimitiveKind.doublePrecision =>
    input ? ConversionOperation.doubleFromJs : ConversionOperation.doubleToJs,
  PrimitiveKind.boolean =>
    input ? ConversionOperation.booleanFromJs : ConversionOperation.booleanToJs,
  PrimitiveKind.string =>
    input ? ConversionOperation.stringFromJs : ConversionOperation.stringToJs,
  PrimitiveKind.voidType => ConversionOperation.voidToJs,
};
