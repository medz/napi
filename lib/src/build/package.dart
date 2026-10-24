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
import 'native_package.dart';
import '../compiler/sdk_adapter/dart_sdk_adapter.dart';

/// Build and assemble an npm package, or replace a managed package.
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
/// root entrypoint. [wasmFallback] lets root ESM imports select Wasm only on
/// unsupported native platforms. It requires both targets and a native root;
/// CommonJS and explicit native/wasm subpaths keep their selected backend.
Future<Directory> buildPackage({
  required Uri library,
  required Directory output,
  required Map<String, Object?> metadata,
  Map<String, File> assets = const {},
  String? packagesPath,
  ExternalLibrary? external,
  BuildTarget target = BuildTarget.wasm,
  Set<BuildTarget>? targets,
  bool wasmFallback = false,
  Directory? nativeRuntime,
}) async {
  final selected = Set<BuildTarget>.of(targets ?? {target});
  _checkWasmFallback(
    selected.map((value) => value.name).toSet(),
    target,
    wasmFallback,
  );
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
      wasmFallback: wasmFallback,
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

/// Assemble separately built platforms and optional Wasm into one npm package.
///
/// Build each native module on its target host with [buildLibrary], then copy
/// the complete output directory, including its ownership record. Modules must
/// have matching public declarations, conversions and defaults. Assembly does
/// not load native code or require a native build host.
///
/// [target] selects the root backend. The native entry selects the current
/// platform from the bundled artifacts and never falls back to Wasm. All
/// selected artifacts ship in the package; there are no install-time downloads.
/// [wasmFallback] enables Wasm on unsupported platforms for root ESM imports
/// when both backends are supplied and [target] is native.
Future<Directory> assemblePackage({
  required List<BuiltModule> modules,
  required Directory output,
  required Map<String, Object?> metadata,
  BuildTarget target = BuildTarget.native,
  bool wasmFallback = false,
  Map<String, File> assets = const {},
}) => _assemblePackage(
  modules: List.of(modules),
  rootTarget: target,
  output: output,
  metadata: metadata,
  assets: assets,
  platformSelection: true,
  wasmFallback: wasmFallback,
);

/// Assemble a lightweight entry package and optional native platform packages.
///
/// Native packages use the root name plus the platform suffix and the same
/// version. npm selects them using os/cpu/libc. Wasm, when supplied, stays in
/// the entry package. The returned directories put native packages first and
/// the entry package last, ready for publication in that order.
///
/// [output] must not exist. The complete set is committed together; use a new
/// directory for each preparation. [assemblePackage] retains all platforms in
/// one package for offline distribution. [wasmFallback] applies only to root
/// ESM imports and requires both backends with a native [target].
Future<List<Directory>> assemblePackageSet({
  required List<BuiltModule> modules,
  required Directory output,
  required Map<String, Object?> metadata,
  BuildTarget target = BuildTarget.native,
  bool wasmFallback = false,
  Map<String, File> assets = const {},
}) async {
  final selected = List<BuiltModule>.of(modules);
  _checkWasmFallback(
    selected.map((value) => value.target.name).toSet(),
    target,
    wasmFallback,
  );
  final supplied = packageMetadata(metadata);
  final destination = output.absolute;
  await checkOutputInputs(destination, [
    for (final module in selected) module.directory,
    ...assets.values,
  ]);
  await _checkAssets(assets);
  if (await FileSystemEntity.type(destination.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw ArgumentError(
      'Package set output already exists: ${destination.path}',
    );
  }
  final native = <NativePlatform, BuiltModule>{};
  final ownership = <BuiltModule, OutputOwnership>{};
  final packages = <NativePlatform, String>{};
  for (final module in selected) {
    final record = await OutputOwnership.read(
      module.directory,
      kind: OutputKind.module,
    );
    if (record == null) {
      throw ArgumentError(
        'Built module does not exist: ${module.directory.path}',
      );
    }
    ownership[module] = record;
    if (module.target != BuildTarget.native) continue;
    final bundle = await NativeRuntimeBundle.read(
      module.directory,
      built: true,
    );
    if (native.containsKey(bundle.platform)) {
      throw ArgumentError(
        'Duplicate native platform: ${bundle.platform.packageId}',
      );
    }
    final name = '${supplied['name']}-${bundle.platform.packageId}';
    packageMetadata({'name': name, 'version': supplied['version']});
    for (final field in [
      'dependencies',
      'optionalDependencies',
      'peerDependencies',
      'devDependencies',
    ]) {
      final dependencies = supplied[field];
      if (dependencies is Map && dependencies.containsKey(name)) {
        throw ArgumentError(
          'Package metadata $field conflicts with generated package $name.',
        );
      }
    }
    native[bundle.platform] = module;
    packages[bundle.platform] = name;
  }
  if (native.isEmpty) {
    throw ArgumentError(
      'A platform package set requires at least one native module.',
    );
  }
  final platforms = native.keys.toList()
    ..sort((a, b) => a.packageId.compareTo(b.packageId));
  await destination.parent.create(recursive: true);
  final staging = await destination.parent.createTemp('.napi-package-set-');
  var committed = false;
  try {
    // Validate the shared contract before copying any native payloads.
    await _assemblePackage(
      modules: selected,
      rootTarget: target,
      output: Directory('${staging.path}/package'),
      metadata: supplied,
      assets: assets,
      platformSelection: true,
      nativePackages: packages,
      wasmFallback: wasmFallback,
    );
    for (final platform in platforms) {
      final payload = Directory('${staging.path}/${platform.packageId}');
      await assembleNativePackage(
        module: native[platform]!,
        output: payload,
        metadata: {
          for (final field in [
            'description',
            'license',
            'repository',
            'homepage',
            'bugs',
            'author',
            'contributors',
            'keywords',
            'engines',
            'publishConfig',
            'private',
          ])
            if (supplied.containsKey(field)) field: supplied[field],
          'name': packages[platform],
          'version': supplied['version'],
        },
        assets: {
          for (final entry in assets.entries)
            if (entry.key.startsWith('LICENSE') ||
                entry.key.startsWith('NOTICE'))
              entry.key: entry.value,
        },
      );
      await ownership[native[platform]]!.verifyArtifacts(payload);
    }
    for (final entry in ownership.entries) {
      await entry.value.verifyArtifacts(entry.key.directory);
    }
    publishDirectory(staging, destination);
    committed = true;
    return [
      for (final platform in platforms)
        Directory('${destination.path}/${platform.packageId}'),
      Directory('${destination.path}/package'),
    ];
  } finally {
    if (!committed) await cleanBuildStaging(staging, committed: false);
  }
}

Future<Directory> _assemblePackage({
  required List<BuiltModule> modules,
  required BuildTarget rootTarget,
  required Directory output,
  required Map<String, Object?> metadata,
  required Map<String, File> assets,
  OutputUpdate? update,
  bool platformSelection = false,
  bool wasmFallback = false,
  Map<NativePlatform, String> nativePackages = const {},
}) async {
  final targets = modules.map((module) => module.target.name).toSet();
  _checkWasmFallback(targets, rootTarget, wasmFallback);
  if (modules.isEmpty || !targets.contains(rootTarget.name)) {
    throw ArgumentError('Package modules must contain the root target.');
  }
  if (modules.where((module) => module.target == BuildTarget.wasm).length > 1) {
    throw ArgumentError('A package can contain only one Wasm module.');
  }
  final supplied = packageMetadata(metadata);
  final nativeOnly =
      !platformSelection &&
      targets.length == 1 &&
      rootTarget == BuildTarget.native;
  packageMetadata(supplied, native: nativeOnly);
  final dual = targets.length > 1;
  final target = output.absolute;
  await checkOutputInputs(target, [
    for (final module in modules) module.directory,
    ...assets.values,
  ]);
  await _checkAssets(assets);
  final files = <String, File>{};
  final generated = <String, String>{};
  final nativeModules = <NativePlatform, String>{};
  final nativeRuntimes = <String, String>{};
  final nativePrefixes = <String>[];
  final moduleOwnership = <String, OutputOwnership>{};
  Map<String, Object?>? contract;
  String? declarations;
  String? runtime;
  NativePlatform? nativePlatform;
  var calls = false;
  var browser = false;
  for (final module in modules) {
    final source = module.directory.absolute;
    await checkOutputPath(source.path);
    if (await FileSystemEntity.type(source.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw ArgumentError('Built module is not a directory: ${source.path}');
    }
    final native = module.target == BuildTarget.native;
    final bundle = native
        ? await NativeRuntimeBundle.read(source, built: true)
        : null;
    if (bundle != null) {
      runtime = bundle.runtime;
      nativePlatform = bundle.platform;
      if (nativeRuntimes.containsKey(bundle.platform.packageId)) {
        throw ArgumentError(
          'Duplicate native platform: ${bundle.platform.packageId}',
        );
      }
      nativeRuntimes[bundle.platform.packageId] = bundle.runtime;
    }
    final prefix = platformSelection && bundle != null
        ? 'native/${bundle.platform.packageId}/'
        : dual
        ? '${module.target.name}/'
        : '';
    if (native) nativePrefixes.add(prefix);
    if (platformSelection || wasmFallback) {
      if (module.sdkVersion != supportedDartSdkVersion) {
        throw ArgumentError(
          'Module SDK version must be $supportedDartSdkVersion.',
        );
      }
      final ownership = await OutputOwnership.read(
        source,
        kind: OutputKind.module,
      );
      final actual = ownership?.moduleContract;
      final exports = actual?['exports'];
      if (actual == null ||
          actual['format'] != 1 ||
          actual['sha256'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(actual['sha256'] as String) ||
          exports is! List ||
          exports.any((name) => name is! String || name == 'then') ||
          exports.toSet().length != exports.length) {
        throw ArgumentError(
          'Module has no compatible package contract; rebuild it with buildLibrary: ${source.path}',
        );
      }
      final text = await File(
        '${source.path}/${native ? 'module.d.mts' : 'module.d.wasm.ts'}',
      ).readAsString();
      if (contract != null &&
          (contract['sha256'] != actual['sha256'] ||
              jsonEncode(contract['exports']) != jsonEncode(exports) ||
              declarations != text)) {
        throw ArgumentError(
          'Module public declarations, conversions or defaults differ: ${source.path}',
        );
      }
      contract = actual;
      declarations = text;
      moduleOwnership[prefix] = ownership!;
      if (bundle != null) {
        nativeModules[bundle.platform] =
            nativePackages[bundle.platform] ??
            './${bundle.platform.packageId}/module.mjs';
      }
    }
    if (bundle != null && nativePackages.isNotEmpty) continue;
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
    final browserFiles = <String, File>{};
    for (final name in native ? <String>[] : wasmBrowserFiles) {
      final file = File('${source.path}/$name');
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        browserFiles['$prefix$name'] = await _regularFile(file);
      }
    }
    if (browserFiles.isNotEmpty &&
        browserFiles.length != wasmBrowserFiles.length) {
      throw ArgumentError('Browser entrypoint artifacts are incomplete.');
    }
    browser = browser || browserFiles.isNotEmpty;
    files.addAll(browserFiles);
  }
  if (platformSelection && nativeModules.isNotEmpty) {
    generated['native/module.mjs'] = emitNativePackageLoader(
      nativeModules,
      (contract!['exports'] as List).cast<String>(),
      packageVersion: nativePackages.isEmpty
          ? null
          : supplied['version'] as String,
    );
    generated['native/module.d.mts'] = declarations!;
  }
  if (wasmFallback) {
    generated['module.mjs'] = emitWasmFallbackLoader(
      nativeModules.keys,
      (contract!['exports'] as List).cast<String>(),
    );
  }
  final artifactNames = {...files.keys, ...generated.keys};
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
    if (nativePackages.isNotEmpty) {
      final optional = package['optionalDependencies'];
      if (optional != null && optional is! Map) {
        throw ArgumentError('optionalDependencies must be a map.');
      }
      package['optionalDependencies'] = {
        ...?optional as Map?,
        for (final name in nativePackages.values) name: supplied['version'],
      };
    }
    package.addAll({
      'type': 'module',
      'files': [...artifactNames, ...selectedAssets],
      'exports': packageEntrypoints(
        targets,
        rootTarget.name,
        nativePlatforms: platformSelection && nativeModules.isNotEmpty,
        browser: browser,
        wasmFallback: wasmFallback,
      ),
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
    for (final entry in generated.entries) {
      final file = File('${staging.path}/${entry.key}');
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value);
    }
    for (final prefix in nativePrefixes) {
      if (nativePackages.isNotEmpty) continue;
      await NativeRuntimeBundle.read(
        Directory('${staging.path}/$prefix'),
        built: true,
      );
    }
    for (final entry in moduleOwnership.entries) {
      if (nativePackages.isNotEmpty && entry.key.startsWith('native/')) {
        continue;
      }
      await entry.value.verifyArtifacts(
        Directory('${staging.path}/${entry.key}'),
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
      runtime: platformSelection ? null : runtime,
      calls: calls,
      browser: browser,
      wasmFallback: wasmFallback,
      assets: selectedAssets,
      autoPlatform: autoPlatform,
      nativeRuntimes: platformSelection && nativePackages.isEmpty
          ? nativeRuntimes
          : const {},
      nativePackages: {
        for (final entry in nativePackages.entries)
          entry.key.packageId: entry.value,
      },
    );
    previous?.copyMetadata(
      staging,
      replacedFiles: {...files.keys, ...generated.keys},
    );
    await previous?.checkUnchanged();
    if (previous == null) {
      publishDirectory(staging, target);
    } else {
      exchangeAttempted = true;
      await update.replace(staging, target);
    }
    published = true;
    if (previous != null) {
      await cleanBuildStaging(staging, committed: true);
    }
    return target;
  } finally {
    try {
      // Once replacement starts, leave its recovery paths intact on failure.
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

void _checkWasmFallback(Set<String> targets, BuildTarget root, bool enabled) {
  if (enabled &&
      (root != BuildTarget.native ||
          !targets.containsAll({'native', 'wasm'}))) {
    throw ArgumentError(
      'wasmFallback requires both backends with a native root.',
    );
  }
}
