import 'dart:convert';
import 'dart:io';

import '../compiler/front_end/external.dart';
import '../compiler/ir/model.dart';
import '../compiler/native/declarations.dart';
import '../compiler/native/plan.dart';
import '../compiler/native/platform.dart';
import 'build.dart';
import 'contract.dart';
import 'metadata.dart';
import 'publish.dart';
import 'output_ownership.dart';
import 'output.dart';
import 'native_bundle.dart';
import 'native_runtime.dart';

/// Build and assemble an npm package, or atomically rebuild a managed package.
///
/// Metadata is validated before source analysis, compilation or staging. Node
/// is not required to validate package names. Native builds obtain a pinned
/// precompiled runtime, or use the explicit offline [nativeRuntime] override.
/// Wasm is the default. Intermediate build files are
/// cleaned up; a postcommit cleanup failure reports the retained path without
/// changing the successful result. Managed output can be rebuilt on
/// qualified macOS and Linux filesystems; legacy or unsupported output is
/// preserved.
/// With [targets], include both backends in one package; [target] chooses the
/// root entrypoint. Explicit native/wasm subpaths never fall back to one another.
Future<Directory> buildPackage({
  required Uri library,
  required Directory output,
  required Map<String, Object?> metadata,
  Map<String, File> assets = const {},
  String? packagesPath,
  ExternalLibrary? external,
  BuildTarget target = BuildTarget.wasm,
  Set<BuildTarget>? targets,
  Directory? nativeRuntime,
}) async {
  final selected = Set<BuildTarget>.of(targets ?? {target});
  final supplied = packageMetadata(metadata);
  final nativeOnly =
      selected.length == 1 && selected.contains(BuildTarget.native);
  packageMetadata(supplied, native: nativeOnly);
  if (selected.isEmpty || !selected.contains(target)) {
    throw ArgumentError('Package targets must contain the root target.');
  }
  if (!selected.contains(BuildTarget.native) && nativeRuntime != null) {
    throw ArgumentError(
      'nativeRuntime is only valid when the package includes native.',
    );
  }
  final destination = output.absolute;
  final packages = libraryPackagesPath(packagesPath, external);
  await checkOutputInputs(destination, [
    if (library.scheme == 'file') File.fromUri(library),
    if (packages != null) File(packages),
    ?nativeRuntime,
    ...assets.values,
  ]);
  await _checkAssets(assets);
  // Reject unsupported existing output before analysis. Fresh dual contracts
  // still fail before creating an output parent or a stable lock inode.
  OutputUpdate? update;
  if (await FileSystemEntity.type(destination.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    update = await OutputUpdate.open(destination);
  }
  Directory? staging;
  var committed = false;
  try {
    packageMetadata({
      ...?update?.previous?.metadata,
      ...supplied,
    }, native: nativeOnly);
    final bindings = <BuildTarget, BindingModule>{};
    String? declarations;
    for (final backend in BuildTarget.values.where(selected.contains)) {
      bindings[backend] = await readLibraryBindings(
        library: library,
        packagesPath: packages,
        external: external,
        target: backend,
      );
    }
    // External package: entrypoints resolve to physical files in the existing
    // frontend. Reuse that result instead of duplicating package resolution.
    await checkOutputInputs(destination, [
      for (final binding in bindings.values) File.fromUri(binding.source),
    ]);
    if (selected.length > 1) {
      declarations = validatePackageContracts(
        bindings[BuildTarget.wasm]!,
        bindings[BuildTarget.native]!,
      );
    } else if (selected.contains(BuildTarget.native)) {
      declarations = emitNativeDeclarations(
        validateNative(bindings[BuildTarget.native]!),
      );
    }
    Directory? runtime;
    if (selected.contains(BuildTarget.native)) {
      final bundle = await resolveNativeRuntime(
        runtime: nativeRuntime,
        output: destination,
      );
      runtime = bundle.directory;
      if (nativeOnly) {
        packageMetadata({
          ...?update?.previous?.metadata,
          ...supplied,
        }, nativePlatform: bundle.platform);
      }
    }
    update ??= await OutputUpdate.open(destination);
    await destination.parent.create(recursive: true);
    staging = await destination.parent.createTemp('.napi-package-build-');
    final modules = <BuiltModule>[];
    for (final backend in BuildTarget.values.where(selected.contains)) {
      final module = await buildModule(
        bindings: bindings[backend]!,
        output: Directory('${staging.path}/${backend.name}'),
        packagesPath: packages,
        target: backend,
        nativeRuntime: backend == BuildTarget.native ? runtime : null,
      );
      if (declarations != null) {
        final name = backend == BuildTarget.native
            ? 'module.d.mts'
            : 'module.d.wasm.ts';
        final actual = await File('${module.directory.path}/$name')
            .readAsString();
        if (actual != declarations) {
          throw StateError(
            'Built $backend declarations changed after validation.',
          );
        }
      }
      modules.add(module);
    }
    final result = await _assemblePackage(
      modules: modules,
      rootTarget: target,
      output: destination,
      metadata: supplied,
      assets: assets,
      update: update,
    );
    committed = true;
    return result;
  } finally {
    try {
      if (staging != null) {
        await cleanBuildStaging(staging, committed: committed);
      }
    } finally {
      update?.close();
    }
  }
}

/// Assemble an npm package from an already built Dart Wasm module.
///
/// Only the known runtime artifacts and explicitly selected documentation assets
/// are copied. [metadata] retains caller-owned JSON fields, including author and
/// contributors. Entrypoints, exports and the file list belong to this builder;
/// supplying those fields is an error rather than a silent override.
///
/// Existing managed output follows the same rebuild rules. Use
/// [assembleNativePackage] for native
/// artifacts; this function has no backend fallback.
Future<Directory> assembleWasmPackage({
  required BuiltModule module,
  required Directory output,
  required Map<String, Object?> metadata,
  Map<String, File> assets = const {},
}) async {
  if (module.target != BuildTarget.wasm) {
    throw ArgumentError('assembleWasmPackage requires a Wasm module.');
  }
  return _assemblePackage(
    modules: [module],
    rootTarget: module.target,
    output: output,
    metadata: metadata,
    assets: assets,
  );
}

/// Assemble one native target without backend fallback or install scripts.
Future<Directory> assembleNativePackage({
  required BuiltModule module,
  required Directory output,
  required Map<String, Object?> metadata,
  Map<String, File> assets = const {},
}) async {
  if (module.target != BuildTarget.native) {
    throw ArgumentError('assembleNativePackage requires a native module.');
  }
  return _assemblePackage(
    modules: [module],
    rootTarget: module.target,
    output: output,
    metadata: metadata,
    assets: assets,
  );
}

Future<Directory> _assemblePackage({
  required List<BuiltModule> modules,
  required BuildTarget rootTarget,
  required Directory output,
  required Map<String, Object?> metadata,
  required Map<String, File> assets,
  OutputUpdate? update,
}) async {
  final supplied = packageMetadata(metadata);
  final nativeOnly = modules.length == 1 && rootTarget == BuildTarget.native;
  packageMetadata(supplied, native: nativeOnly);
  final dual = modules.length > 1;
  final target = output.absolute;
  await checkOutputInputs(target, [
    for (final module in modules) module.directory,
    ...assets.values,
  ]);
  await _checkAssets(assets);
  final files = <String, File>{};
  String? runtime;
  NativePlatform? nativePlatform;
  var calls = false;
  for (final module in modules) {
    final source = module.directory.absolute;
    await checkOutputPath(source.path);
    if (await FileSystemEntity.type(source.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw ArgumentError('Built module is not a directory: ${source.path}');
    }
    final prefix = dual ? '${module.target.name}/' : '';
    final native = module.target == BuildTarget.native;
    final bundle = native
        ? await NativeRuntimeBundle.read(source, built: true)
        : null;
    if (bundle != null) {
      runtime = bundle.runtime;
      nativePlatform = bundle.platform;
    }
    final requiredFiles = bundle == null
        ? wasmPackageFiles
        : [
            'module.mjs',
            'module.d.mts',
            'module.aot',
            'runtime.json',
            ...bundle.hashes.keys,
          ];
    for (final name in requiredFiles) {
      files['$prefix$name'] = await _regularFile(File('${source.path}/$name'));
    }
    final callFiles = <String, File>{};
    for (final name in native ? <String>[] : wasmCallFiles) {
      final file = File('${source.path}/$name');
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        callFiles['$prefix$name'] = await _regularFile(file);
      }
    }
    if (callFiles.isNotEmpty && callFiles.length != wasmCallFiles.length) {
      throw ArgumentError(
        'Callable artifacts require core.wasm, calls.mjs and references.mjs.',
      );
    }
    calls = calls || callFiles.isNotEmpty;
    files.addAll(callFiles);
  }
  final artifactNames = files.keys.toSet();
  for (final name in assets.keys.toList()..sort()) {
    if (!packageAssetNames.contains(name)) {
      throw ArgumentError('Unsupported package asset name: $name');
    }
    files[name] = await _regularFile(assets[name]!);
  }

  final ownsUpdate = update == null;
  update ??= await OutputUpdate.open(target);
  Directory? staging;
  var published = false;
  var exchangeAttempted = false;
  try {
    final previous = update.previous;
    final author = {...?previous?.metadata, ...supplied};
    final autoPlatform = <String>{
      if (nativeOnly)
        for (final field in [
          'os',
          'cpu',
          if (nativePlatform?.libc != null) 'libc',
        ])
          if (!author.containsKey(field)) field,
    };
    final selectedAssets = {...?previous?.assets, ...assets.keys};
    final package = packageMetadata(
      author,
      nativePlatform: nativeOnly ? nativePlatform : null,
    );
    final targets = modules.map((module) => module.target.name).toSet();
    package.addAll({
      'type': 'module',
      'files': [...artifactNames, ...selectedAssets],
      'exports': packageEntrypoints(targets, rootTarget.name),
    });
    staging = await target.parent.createTemp('.napi-package-');
    if (previous != null) {
      await previous.copyAuthors(staging, {
        ...artifactNames,
        ...assets.keys.where((name) => !previous.assets.contains(name)),
      }, replacedAssets: assets.keys.toSet());
    }
    for (final entry in files.entries) {
      final destination = File('${staging.path}/${entry.key}');
      await destination.parent.create(recursive: true);
      await entry.value.copy(destination.path);
    }
    for (final module in modules.where((m) => m.target == BuildTarget.native)) {
      await NativeRuntimeBundle.read(
        dual ? Directory('${staging.path}/${module.target.name}') : staging,
        built: true,
      );
    }
    await File(
      '${staging.path}/package.json',
    ).writeAsString('${const JsonEncoder.withIndent('  ').convert(package)}\n');
    await writeOutputOwnership(
      staging,
      kind: OutputKind.package,
      targets: targets,
      root: rootTarget.name,
      runtime: runtime,
      calls: calls,
      assets: selectedAssets,
      autoPlatform: autoPlatform,
    );
    previous?.copyMetadata(staging, replacedFiles: files.keys.toSet());
    await previous?.checkUnchanged();
    if (previous == null) {
      publishDirectory(staging, target);
    } else {
      exchangeAttempted = true;
      exchangeDirectories(staging, target);
    }
    published = true;
    if (previous != null) {
      await cleanBuildStaging(staging, committed: true);
    }
    return target;
  } finally {
    try {
      // Exchange errors retain both names for inspection; there is no fallback
      // rename and no assumption that an ambiguous error means no commit.
      if (!published && !exchangeAttempted && staging != null) {
        await cleanBuildStaging(staging, committed: false);
      }
    } finally {
      if (ownsUpdate) update.close();
    }
  }
}

Future<void> _checkAssets(Map<String, File> assets) async {
  for (final entry in assets.entries) {
    if (!packageAssetNames.contains(entry.key)) {
      throw ArgumentError('Unsupported package asset name: ${entry.key}');
    }
    await _regularFile(entry.value);
  }
}

Future<File> _regularFile(File file) async {
  await checkOutputPath(file.absolute.path);
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw ArgumentError('Package input is not a regular file: ${file.path}');
  }
  return file;
}
