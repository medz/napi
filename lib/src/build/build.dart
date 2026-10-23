import 'dart:io';

import '../compiler/analysis/validate.dart';
import '../compiler/emit/dart/entrypoint.dart';
import '../compiler/emit/js/boundary.dart';
import '../compiler/emit/js/arguments.dart';
import '../compiler/emit/js/references.dart';
import '../compiler/emit/typescript/declarations.dart';
import '../compiler/front_end/frontend.dart';
import '../compiler/front_end/external.dart';
import '../compiler/ir/model.dart';
import '../compiler/linker/dart_module_linker.dart';
import '../compiler/lowering/plan.dart';
import '../compiler/native/plan.dart';
import '../compiler/sdk_adapter/dart_sdk_adapter.dart';
import 'publish.dart';
import 'native.dart';
import 'native_runtime.dart';
import 'output.dart';
import 'output_ownership.dart';
import 'contract.dart';

enum BuildTarget { wasm, native }

final class BuiltModule {
  final Directory directory;
  final String sdkVersion;
  final BuildTarget target;
  const BuiltModule(
    this.directory,
    this.sdkVersion, {
    this.target = BuildTarget.wasm,
  });
  File get wasm => File('${directory.path}/module.wasm');
  File get entrypoint => File(
    '${directory.path}/${target == BuildTarget.wasm ? 'module.wasm' : 'module.mjs'}',
  );
}

/// Discover selected declarations and build the requested target.
///
/// Unsupported selected declarations fail before output or staging is created.
Future<BuiltModule> buildLibrary({
  required Uri library,
  required Directory output,
  String? packagesPath,
  ExternalLibrary? external,
  BindingFrontend? frontend,
  DartSdkAdapter? sdk,
  BuildTarget target = BuildTarget.wasm,
  Directory? nativeRuntime,
}) async {
  final effectivePackages = libraryPackagesPath(packagesPath, external);
  final bindings = await readLibraryBindings(
    library: library,
    packagesPath: effectivePackages,
    external: external,
    frontend: frontend,
    target: target,
  );
  final destination = output.absolute;
  if (await FileSystemEntity.type(destination.path, followLinks: false) ==
      FileSystemEntityType.notFound) {
    return buildModule(
      bindings: bindings,
      output: destination,
      sdk: sdk,
      packagesPath: effectivePackages,
      target: target,
      nativeRuntime: nativeRuntime,
    );
  }
  if (target == BuildTarget.native) {
    validateNative(bindings);
  } else {
    validate(bindings);
  }
  await checkOutputInputs(destination, [
    File.fromUri(bindings.source),
    if (effectivePackages != null) File(effectivePackages),
    ?nativeRuntime,
    if (target == BuildTarget.native && nativeRuntime == null)
      nativeRuntimeCacheDirectory(),
  ]);
  final update = await OutputUpdate.open(destination, kind: OutputKind.module);
  Directory? staging;
  var committed = false;
  var exchangeAttempted = false;
  try {
    staging = await destination.parent.createTemp('.napi-module-rebuild-');
    final module = await buildModule(
      bindings: bindings,
      output: Directory('${staging.path}/compiled'),
      sdk: sdk,
      packagesPath: effectivePackages,
      target: target,
      nativeRuntime: nativeRuntime,
    );
    final ownership = (await OutputOwnership.read(
      module.directory,
      kind: OutputKind.module,
    ))!;
    final merged = await Directory('${staging.path}/merged').create();
    final previous = update.previous;
    await previous?.copyAuthors(merged, ownership.artifacts);
    for (final name in [...ownership.artifacts, outputOwnershipFile]) {
      await File('${module.directory.path}/$name').copy('${merged.path}/$name');
    }
    previous?.copyMetadata(merged, replacedFiles: ownership.artifacts);
    await previous?.checkUnchanged();
    if (previous == null) {
      publishDirectory(merged, destination);
    } else {
      exchangeAttempted = true;
      try {
        exchangeDirectories(merged, destination);
      } on FileSystemException catch (error) {
        throw FileSystemException(
          '${error.message} Rebuild files retained at ${staging.path}.',
          error.path,
          error.osError,
        );
      }
    }
    committed = true;
    return BuiltModule(destination, module.sdkVersion, target: module.target);
  } finally {
    try {
      if (staging != null && (committed || !exchangeAttempted)) {
        await cleanBuildStaging(staging, committed: committed);
      }
    } finally {
      update.close();
    }
  }
}

String? libraryPackagesPath(String? packagesPath, ExternalLibrary? external) {
  final defaults = File('.dart_tool/package_config.json').absolute;
  return packagesPath ??
      (external != null && defaults.existsSync() ? defaults.path : null);
}

/// Resolve each backend's conditional imports before comparing package APIs.
Future<BindingModule> readLibraryBindings({
  required Uri library,
  String? packagesPath,
  ExternalLibrary? external,
  BindingFrontend? frontend,
  BuildTarget target = BuildTarget.wasm,
}) async {
  if (external != null && frontend != null) {
    throw ArgumentError('Provide external selections or a frontend, not both.');
  }
  final effectivePackages = libraryPackagesPath(packagesPath, external);
  final selectedFrontend =
      frontend ??
      (external == null
          ? AnnotationFrontend(
              packagesPath: effectivePackages,
              native: target == BuildTarget.native,
            )
          : ExternalFrontend(
              external,
              packagesPath: effectivePackages,
              native: target == BuildTarget.native,
            ));
  return selectedFrontend.read(library);
}

/// Build fresh artifacts from semantic IR.
///
/// The destination must not exist. Compilation and linking finish in a sibling
/// staging directory before an atomic no-replace rename publishes the artifacts.
/// Package assembly and managed output replacement are handled by the callers.
Future<BuiltModule> buildModule({
  required BindingModule bindings,
  required Directory output,
  DartSdkAdapter? sdk,
  String? packagesPath,
  BuildTarget target = BuildTarget.wasm,
  Directory? nativeRuntime,
}) async {
  checkOutputLockPath(output);
  if (target == BuildTarget.native) {
    return buildNativeModule(
      bindings: bindings,
      output: output,
      runtime: nativeRuntime,
      packagesPath: packagesPath,
      executable: sdk?.executable,
    );
  }
  if (nativeRuntime != null) {
    throw ArgumentError('nativeRuntime is only valid for BuildTarget.native.');
  }
  final analysis = validate(bindings);
  final plan = lower(analysis);
  final declarations = emitDeclarations(plan);
  final callableGlobals = plan.functions
      .where((f) => f.representation == ExportRepresentation.callableGlobal)
      .toList();
  final hasCalls = callableGlobals.isNotEmpty || plan.classes.isNotEmpty;
  final destination = output.absolute;
  if (await FileSystemEntity.type(destination.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw ArgumentError('Output already exists: ${destination.path}');
  }
  if (!await File.fromUri(bindings.source).exists()) {
    throw ArgumentError('Source library does not exist: ${bindings.source}');
  }
  await destination.parent.create(recursive: true);
  final staging = await destination.parent.createTemp('.napi-build-');
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
      await File('${artifact.path}/references.mjs')
          .writeAsString(emitReferences());
      await File('${artifact.path}/calls.mjs')
          .writeAsString(emitArgumentCalls(plan));
      await File('${artifact.path}/module.wasm').writeAsBytes(
        buildPublicWasmFacade(
          hostSpecifier: './calls.mjs',
          exportNames: [
            ...callableGlobals.map((f) => f.binding.exportName),
            ...plan.classes.map((c) => c.binding.exportName),
          ],
          nativeFunctions: {
            for (final f in plan.functions)
              if (f.representation == ExportRepresentation.nativeFunction)
                f.binding.exportName: f.inputs.length,
          },
          voidFunctions: {
            for (final f in plan.functions)
              if (f.representation == ExportRepresentation.nativeFunction &&
                  f.output == null)
                f.binding.exportName,
          },
        ),
      );
    }
    await File('${artifact.path}/host.mjs')
        .writeAsString(linked.hostJavaScript);
    await File('${artifact.path}/boundary.mjs')
        .writeAsString(emitBoundary(plan));
    await File('${artifact.path}/module.d.wasm.ts').writeAsString(declarations);
    await File(compiled.sdkLicensePath).copy('${artifact.path}/DART_LICENSE');
    await writeOutputOwnership(
      artifact,
      kind: OutputKind.module,
      targets: {'wasm'},
      root: 'wasm',
      runtime: null,
      calls: hasCalls,
      moduleContract: await createModuleContract(
        analysis.bindings,
        analysis.classes,
        analysis.valueSchemas,
        declarations,
        packagesPath: packagesPath,
      ),
    );
    publishDirectory(artifact, destination);
    return BuiltModule(destination, compiled.version);
  } finally {
    if (await staging.exists()) await staging.delete(recursive: true);
  }
}
