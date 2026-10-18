import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../compiler/front_end/external.dart';
import '../compiler/ir/model.dart';
import 'build.dart';
import 'contract.dart';
import 'metadata.dart';
import 'publish.dart';
import 'native_bundle.dart';

const _requiredFiles = [
  'module.wasm',
  'module.d.wasm.ts',
  'host.mjs',
  'boundary.mjs',
  'DART_LICENSE',
];
const _callFiles = ['core.wasm', 'calls.mjs', 'references.mjs'];
const _assetNames = {
  'README',
  'README.md',
  'LICENSE',
  'LICENSE.md',
  'LICENSE.txt',
  'NOTICE',
  'NOTICE.md',
  'NOTICE.txt',
  'CHANGELOG.md',
};

/// Build and assemble a fresh npm package in one operation.
///
/// Metadata is validated before source analysis, compilation or staging. Node
/// is not required to validate package names. Native builds use [nativeRuntime]
/// and [BuildTarget.native]; Wasm is the default. All intermediate build files
/// are removed on success or failure. Existing [output] is never replaced.
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
  final package = packageMetadata(
    metadata,
    native: selected.length == 1 && selected.contains(BuildTarget.native),
  );
  if (selected.isEmpty || !selected.contains(target)) {
    throw ArgumentError('Package targets must contain the root target.');
  }
  if (selected.contains(BuildTarget.native) != (nativeRuntime != null)) {
    throw ArgumentError(
      'nativeRuntime is required exactly when the package includes native.',
    );
  }
  final destination = output.absolute;
  await _checkPath(destination.path);
  if (await FileSystemEntity.type(destination.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw ArgumentError('Package output already exists: ${destination.path}');
  }
  final bindings = <BuildTarget, BindingModule>{};
  String? declarations;
  final packages = libraryPackagesPath(packagesPath, external);
  if (selected.length > 1) {
    final bundle = await NativeRuntimeBundle.read(nativeRuntime!);
    bundle.verifyHost();
    for (final backend in BuildTarget.values) {
      bindings[backend] = await readLibraryBindings(
        library: library,
        packagesPath: packages,
        external: external,
        target: backend,
      );
    }
    declarations = validatePackageContracts(
      bindings[BuildTarget.wasm]!,
      bindings[BuildTarget.native]!,
    );
  }
  await destination.parent.create(recursive: true);
  final staging = await destination.parent.createTemp('.napi-package-build-');
  try {
    final modules = <BuiltModule>[];
    for (final backend in BuildTarget.values.where(selected.contains)) {
      final module = bindings.isEmpty
          ? await buildLibrary(
              library: library,
              output: Directory('${staging.path}/${backend.name}'),
              packagesPath: packages,
              external: external,
              target: backend,
              nativeRuntime: backend == BuildTarget.native
                  ? nativeRuntime
                  : null,
            )
          : await buildModule(
              bindings: bindings[backend]!,
              output: Directory('${staging.path}/${backend.name}'),
              packagesPath: packages,
              target: backend,
              nativeRuntime: backend == BuildTarget.native
                  ? nativeRuntime
                  : null,
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
    return await _assemblePackage(
      modules: modules,
      rootTarget: target,
      output: destination,
      metadata: package,
      assets: assets,
    );
  } finally {
    if (await staging.exists()) await staging.delete(recursive: true);
  }
}

/// Assemble a fresh npm package from an already built Dart Wasm module.
///
/// Only the known runtime artifacts and explicitly selected documentation assets
/// are copied. [metadata] retains caller-owned JSON fields, including author and
/// contributors. Entrypoints, exports and the file list belong to this builder;
/// supplying those fields is an error rather than a silent override.
///
/// Existing output is never replaced. Use [assembleNativePackage] for native
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
}) async {
  final package = packageMetadata(
    metadata,
    native: modules.length == 1 && rootTarget == BuildTarget.native,
  );
  final dual = modules.length > 1;
  final target = output.absolute;
  await _checkPath(target.path);
  if (await FileSystemEntity.type(target.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw ArgumentError('Package output already exists: ${target.path}');
  }
  final files = <String, File>{};
  for (final module in modules) {
    final source = module.directory.absolute;
    await _checkPath(source.path);
    if (await FileSystemEntity.type(source.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw ArgumentError('Built module is not a directory: ${source.path}');
    }
    if (path.isWithin(source.path, target.path) ||
        path.equals(source.path, target.path)) {
      throw ArgumentError('Package output must be outside the built module.');
    }
    final prefix = dual ? '${module.target.name}/' : '';
    final native = module.target == BuildTarget.native;
    final bundle = native
        ? await NativeRuntimeBundle.read(source, built: true)
        : null;
    final requiredFiles = bundle == null
        ? _requiredFiles
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
    for (final name in native ? <String>[] : _callFiles) {
      final file = File('${source.path}/$name');
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        callFiles['$prefix$name'] = await _regularFile(file);
      }
    }
    if (callFiles.isNotEmpty && callFiles.length != _callFiles.length) {
      throw ArgumentError(
        'Callable artifacts require core.wasm, calls.mjs and references.mjs.',
      );
    }
    files.addAll(callFiles);
  }
  for (final name in assets.keys.toList()..sort()) {
    if (!_assetNames.contains(name)) {
      throw ArgumentError('Unsupported package asset name: $name');
    }
    files[name] = await _regularFile(assets[name]!);
  }

  Map<String, String> entry(BuildTarget backend) {
    final prefix = dual ? './${backend.name}/' : './';
    return {
      'types':
          '$prefix${backend == BuildTarget.native ? 'module.d.mts' : 'module.d.wasm.ts'}',
      'import':
          '$prefix${backend == BuildTarget.native ? 'module.mjs' : 'module.wasm'}',
    };
  }

  package.addAll({
    'type': 'module',
    'files': files.keys.toList(),
    'exports': {
      '.': entry(rootTarget),
      if (modules.any((m) => m.target == BuildTarget.native))
        './native': entry(BuildTarget.native),
      if (dual) './wasm': entry(BuildTarget.wasm),
      if (modules.any((m) => m.target == BuildTarget.wasm))
        './module.wasm': entry(BuildTarget.wasm),
    },
  });
  final manifest = const JsonEncoder.withIndent('  ').convert(package);
  await target.parent.create(recursive: true);
  final staging = await target.parent.createTemp('.napi-package-');
  var published = false;
  try {
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
    await File('${staging.path}/package.json').writeAsString('$manifest\n');
    publishDirectory(staging, target);
    published = true;
    return target;
  } finally {
    if (!published && await staging.exists()) {
      await staging.delete(recursive: true);
    }
  }
}

Future<File> _regularFile(File file) async {
  await _checkPath(file.absolute.path);
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw ArgumentError('Package input is not a regular file: ${file.path}');
  }
  return file;
}

Future<void> _checkPath(String value) async {
  if (value.contains('\x00') || path.split(value).contains('..')) {
    throw ArgumentError(
      'Package paths must not contain NUL or traversal: $value',
    );
  }
  var current = path.rootPrefix(value);
  for (final segment in path.split(value).skip(1)) {
    current = path.join(current, segment);
    if (await FileSystemEntity.type(current, followLinks: false) ==
        FileSystemEntityType.link) {
      throw ArgumentError('Package paths must not contain symlinks: $current');
    }
  }
}
