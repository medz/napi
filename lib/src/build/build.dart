import 'dart:io';

import '../compiler/analysis/validate.dart';
import '../compiler/emit/dart/entrypoint.dart';
import '../compiler/emit/js/boundary.dart';
import '../compiler/emit/js/arguments.dart';
import '../compiler/emit/typescript/declarations.dart';
import '../compiler/front_end/frontend.dart';
import '../compiler/front_end/external.dart';
import '../compiler/ir/model.dart';
import '../compiler/linker/dart_module_linker.dart';
import '../compiler/lowering/plan.dart';
import '../compiler/sdk_adapter/dart_sdk_adapter.dart';
import 'publish.dart';

final class BuiltModule {
  final Directory directory;
  final String sdkVersion;
  const BuiltModule(this.directory, this.sdkVersion);
  File get wasm => File('${directory.path}/module.wasm');
}

/// Discover selected declarations and build their supported direct-Wasm API.
///
/// Unsupported selected declarations fail before output or staging is created.
Future<BuiltModule> buildLibrary({
  required Uri library,
  required Directory output,
  String? packagesPath,
  ExternalLibrary? external,
  BindingFrontend? frontend,
  DartSdkAdapter? sdk,
}) async {
  if (external != null && frontend != null) {
    throw ArgumentError('Provide external selections or a frontend, not both.');
  }
  final defaultPackages = File('.dart_tool/package_config.json').absolute;
  final effectivePackages =
      packagesPath ??
      (external != null && defaultPackages.existsSync()
          ? defaultPackages.path
          : null);
  final selectedFrontend =
      frontend ??
      (external == null
          ? AnnotationFrontend(packagesPath: effectivePackages)
          : ExternalFrontend(external, packagesPath: effectivePackages));
  return buildModule(
    bindings: await selectedFrontend.read(library),
    output: output,
    sdk: sdk,
    packagesPath: effectivePackages,
  );
}

/// Build fresh artifacts from semantic IR.
///
/// The destination must not exist. Compilation and linking finish in a sibling
/// staging directory before an atomic no-replace rename publishes the artifacts.
/// This intentionally does not implement the package/rebuild system in #134/135.
Future<BuiltModule> buildModule({
  required BindingModule bindings,
  required Directory output,
  DartSdkAdapter? sdk,
  String? packagesPath,
}) async {
  final plan = lower(validate(bindings));
  final callableGlobals = plan.functions
      .where((f) => f.representation == ExportRepresentation.callableGlobal)
      .toList();
  final hasCalls = callableGlobals.isNotEmpty;
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
      coreSpecifier: hasCalls ? './core.wasm' : './module.wasm',
      additionalImports: {'napi': './boundary.mjs'},
    );
    final artifact = await Directory('${staging.path}/artifact').create();
    await File('${artifact.path}/${hasCalls ? 'core' : 'module'}.wasm')
        .writeAsBytes(linked.wasmBytes);
    if (hasCalls) {
      await File('${artifact.path}/calls.mjs')
          .writeAsString(emitArgumentCalls(plan));
      await File('${artifact.path}/module.wasm').writeAsBytes(
        buildPublicWasmFacade(
          hostSpecifier: './calls.mjs',
          exportNames: callableGlobals
              .map((f) => f.binding.exportName)
              .toList(),
          nativeFunctions: {
            for (final f in plan.functions)
              if (f.representation == ExportRepresentation.nativeFunction)
                f.binding.exportName: f.inputs.length,
          },
        ),
      );
    }
    await File('${artifact.path}/host.mjs')
        .writeAsString(linked.hostJavaScript);
    await File('${artifact.path}/boundary.mjs')
        .writeAsString(emitBoundary(plan));
    await File('${artifact.path}/module.d.wasm.ts')
        .writeAsString(emitDeclarations(plan));
    await File(compiled.sdkLicensePath).copy('${artifact.path}/DART_LICENSE');
    publishDirectory(artifact, target);
    return BuiltModule(target, compiled.version);
  } finally {
    if (await staging.exists()) await staging.delete(recursive: true);
  }
}
