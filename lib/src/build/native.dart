import 'dart:io';

import '../compiler/ir/model.dart';
import '../compiler/lowering/plan.dart'
    show AbortSignalConversion, OpaqueConversion, conversionDependencies;
import '../compiler/native/plan.dart';
import '../compiler/native/entrypoint.dart';
import '../compiler/native/declarations.dart';
import '../compiler/native/loader.dart';
import '../compiler/sdk_adapter/dart_aot_adapter.dart';
import '../compiler/sdk_adapter/dart_sdk_adapter.dart';
import 'build.dart';
import 'native_bundle.dart';
import 'native_runtime.dart';
import 'publish.dart';
import 'output_ownership.dart';
import 'contract.dart';

Future<BuiltModule> buildNativeModule({
  required BindingModule bindings,
  required Directory output,
  Directory? runtime,
  String? packagesPath,
  String? executable,
}) async {
  final plan = validateNative(bindings);
  final declarations = emitNativeDeclarations(plan);
  final target = output.absolute;
  await checkNativePath(target.path);
  if (await FileSystemEntity.type(target.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw ArgumentError('Output already exists: ${target.path}');
  }
  if (!File.fromUri(bindings.source).existsSync()) {
    throw ArgumentError('Source library does not exist: ${bindings.source}');
  }
  final bundle = await resolveNativeRuntime(runtime: runtime, output: target);
  await target.parent.create(recursive: true);
  final staging = await target.parent.createTemp('.napi-native-');
  try {
    final source = File('${staging.path}/entrypoint.dart');
    await source.writeAsString(emitNativeDart(plan));
    final artifact = await Directory('${staging.path}/artifact').create();
    await DartAotAdapter(executable: executable).compile(
      sourcePath: source.path,
      outputPath: '${artifact.path}/module.aot',
      packagesPath: packagesPath,
    );
    await bundle.copyTo(artifact);
    final exports = [
      for (final function in plan.functions) function.exportName,
      for (final binding in plan.classes) binding.binding.exportName,
    ];
    await File('${artifact.path}/module.mjs').writeAsString(
      emitNativeLoader(
        exports,
        platform: bundle.platform,
        classes: plan.classes,
        functionValues: plan.functionValues,
        hasBinary: plan.hasBinary,
        hasOpaque: conversionDependencies(
          plan.calls.expand((call) => [...call.inputs, ?call.output]),
        ).any((value) => value is OpaqueConversion),
        jsCollections: plan.jsCollections,
        hasFutures: plan.hasFutures,
        streamClassName: plan.hasStreams ? plan.streamClassName : null,
        hasCallbacks: plan.callbacks.any(
          (input) => input.direction == ValueDirection.input,
        ),
        hasAsyncCallbacks: plan.callbacks.any(
          (input) =>
              input.direction == ValueDirection.input &&
              (input.returnsFuture || input.returnsStream),
        ),
        hasStreamCallbacks: plan.callbacks.any(
          (input) =>
              input.direction == ValueDirection.input && input.returnsStream,
        ),
        hasSignals: plan.calls.any(
          (call) => call.inputs.any((input) => input is AbortSignalConversion),
        ),
      ),
    );
    await File('${artifact.path}/module.d.mts').writeAsString(declarations);
    await writeOutputOwnership(
      artifact,
      kind: OutputKind.module,
      targets: {'native'},
      root: 'native',
      runtime: bundle.runtime,
      calls: false,
      moduleContract: await createModuleContract(
        plan.bindings,
        plan.classes.map((c) => c.shape).toList(),
        plan.valueSchemas,
        declarations,
        packagesPath: packagesPath,
      ),
    );
    publishDirectory(artifact, target);
    return BuiltModule(
      target,
      supportedDartSdkVersion,
      target: BuildTarget.native,
    );
  } finally {
    if (await staging.exists()) await staging.delete(recursive: true);
  }
}
