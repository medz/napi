import 'dart:io';

import '../compiler/ir/model.dart';
import '../compiler/native/plan.dart';
import '../compiler/native/entrypoint.dart';
import '../compiler/native/declarations.dart';
import '../compiler/native/loader.dart';
import '../compiler/sdk_adapter/dart_aot_adapter.dart';
import '../compiler/sdk_adapter/dart_sdk_adapter.dart';
import 'build.dart';
import 'native_bundle.dart';
import 'publish.dart';

Future<BuiltModule> buildNativeModule({
  required BindingModule bindings,
  required Directory output,
  required Directory runtime,
  String? packagesPath,
  String? executable,
}) async {
  final plan = validateNative(bindings);
  final target = output.absolute;
  await checkNativePath(target.path);
  if (await FileSystemEntity.type(target.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw ArgumentError('Output already exists: ${target.path}');
  }
  if (!File.fromUri(bindings.source).existsSync()) {
    throw ArgumentError('Source library does not exist: ${bindings.source}');
  }
  final bundle = await NativeRuntimeBundle.read(runtime);
  bundle.verifyHost();
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
      for (final function in bindings.functions) function.exportName,
      for (final binding in bindings.classes) binding.exportName,
    ];
    await File('${artifact.path}/module.mjs')
        .writeAsString(emitNativeLoader(exports));
    await File('${artifact.path}/module.d.mts')
        .writeAsString(emitNativeDeclarations(plan));
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
