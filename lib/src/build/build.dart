import 'dart:io';

import '../compiler/analysis/validate.dart';
import '../compiler/emit/dart/entrypoint.dart';
import '../compiler/emit/js/boundary.dart';
import '../compiler/emit/typescript/declarations.dart';
import '../compiler/ir/model.dart';
import '../compiler/linker/dart_module_linker.dart';
import '../compiler/lowering/plan.dart';
import '../compiler/sdk_adapter/dart_sdk_adapter.dart';

final class BuiltModule {
  final Directory directory;
  final String sdkVersion;
  const BuiltModule(this.directory, this.sdkVersion);
  File get wasm => File('${directory.path}/module.wasm');
}

/// Build fresh artifacts from semantic IR. Annotation discovery is separate.
///
/// The destination must not exist. Compilation and linking finish in a sibling
/// staging directory before a completed artifact directory is renamed into place.
/// This intentionally does not implement the package/rebuild system in #134/135.
Future<BuiltModule> buildModule({
  required BindingModule bindings,
  required Directory output,
  DartSdkAdapter? sdk,
  String? packagesPath,
}) async {
  final plan = lower(validate(bindings));
  final target = output.absolute;
  if (await FileSystemEntity.type(target.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw ArgumentError('Output already exists: ${target.path}');
  }
  if (!await File.fromUri(bindings.source).exists()) {
    throw ArgumentError('Source library does not exist: ${bindings.source}');
  }
  await target.parent.create(recursive: true);
  final staging = await target.parent.createTemp('.napi-build-');
  try {
    final source = File('${staging.path}/entrypoint.dart');
    await source.writeAsString(emitDart(plan));
    final compiled = await (sdk ?? DartSdkAdapter()).compile(
      sourcePath: source.path,
      outputPath: '${staging.path}/raw.wasm',
      packagesPath: packagesPath,
    );
    final linked = linkDartModule(
      rawWasmBytes: await File(compiled.wasmPath).readAsBytes(),
      rawMjsText: await File(compiled.jsPath).readAsString(),
      hostSpecifier: './host.mjs',
      coreSpecifier: './module.wasm',
      additionalImports: {'napi': './boundary.mjs'},
    );
    final artifact = await Directory('${staging.path}/artifact').create();
    await File('${artifact.path}/module.wasm').writeAsBytes(linked.wasmBytes);
    await File('${artifact.path}/host.mjs')
        .writeAsString(linked.hostJavaScript);
    await File('${artifact.path}/boundary.mjs')
        .writeAsString(emitBoundary(plan));
    await File('${artifact.path}/module.d.wasm.ts')
        .writeAsString(emitDeclarations(plan));
    await File(compiled.sdkLicensePath).copy('${artifact.path}/DART_LICENSE');
    await artifact.rename(target.path);
    return BuiltModule(target, compiled.version);
  } finally {
    if (await staging.exists()) await staging.delete(recursive: true);
  }
}
