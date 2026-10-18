import '../emit/typescript/declarations.dart';
import 'plan.dart';

/// Declaration spelling and public types are shared across both backends.
/// Native ABI calls and lifecycle metadata remain in [NativeModulePlan].
String emitNativeDeclarations(NativeModulePlan plan) => emitBindingDeclarations(
  functions: plan.bindings.functions,
  classes: plan.bindings.classes,
  references: plan.classes.map((c) => c.shape).toList(),
  values: plan.valueSchemas,
);
