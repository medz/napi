import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'build.dart';
import 'publish.dart';
import 'native_bundle.dart';

const _requiredFiles = [
  'module.wasm',
  'module.d.wasm.ts',
  'host.mjs',
  'boundary.mjs',
  'DART_LICENSE',
];
const _callFiles = ['core.wasm', 'calls.mjs'];
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
const _generatedFields = {
  'type',
  'files',
  'exports',
  'imports',
  'main',
  'module',
  'types',
  'typings',
  'browser',
  'bin',
};

/// Assemble a fresh npm package from an already built Dart Wasm module.
///
/// Only the known runtime artifacts and explicitly selected documentation assets
/// are copied. [metadata] retains caller-owned JSON fields, including author and
/// contributors. Entrypoints, exports and the file list belong to this builder;
/// supplying those fields is an error rather than a silent override.
///
/// Existing output is never replaced. Native package assembly and replacement
/// builds remain separate requirements; this function has no backend fallback.
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
    module: module,
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
    module: module,
    output: output,
    metadata: metadata,
    assets: assets,
  );
}

Future<Directory> _assemblePackage({
  required BuiltModule module,
  required Directory output,
  required Map<String, Object?> metadata,
  required Map<String, File> assets,
}) async {
  final package = await _packageMetadata(metadata);
  final source = module.directory.absolute;
  final target = output.absolute;
  await _checkPath(source.path);
  if (await FileSystemEntity.type(source.path, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw ArgumentError('Built module is not a directory: ${source.path}');
  }
  await _checkPath(target.path);
  if (await FileSystemEntity.type(target.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw ArgumentError('Package output already exists: ${target.path}');
  }
  if (path.isWithin(source.path, target.path) ||
      path.equals(source.path, target.path)) {
    throw ArgumentError('Package output must be outside the built module.');
  }

  final files = <String, File>{};
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
    files[name] = await _regularFile(File('${source.path}/$name'));
  }
  final callFiles = <String, File>{};
  for (final name in native ? <String>[] : _callFiles) {
    final file = File('${source.path}/$name');
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      callFiles[name] = await _regularFile(file);
    }
  }
  if (callFiles.isNotEmpty && callFiles.length != _callFiles.length) {
    throw ArgumentError(
      'Callable artifacts require both core.wasm and calls.mjs.',
    );
  }
  files.addAll(callFiles);
  for (final name in assets.keys.toList()..sort()) {
    if (!_assetNames.contains(name)) {
      throw ArgumentError('Unsupported package asset name: $name');
    }
    files[name] = await _regularFile(assets[name]!);
  }

  package.addAll({
    'type': 'module',
    'files': files.keys.toList(),
    'exports': {
      for (final key in ['.', native ? './native' : './module.wasm'])
        key: {
          'types': native ? './module.d.mts' : './module.d.wasm.ts',
          'import': native ? './module.mjs' : './module.wasm',
        },
    },
  });
  if (native) {
    for (final entry in {
      'os': ['darwin'],
      'cpu': ['arm64'],
    }.entries) {
      if (package.containsKey(entry.key) &&
          jsonEncode(package[entry.key]) != jsonEncode(entry.value)) {
        throw ArgumentError(
          'Native package metadata ${entry.key} must match ${entry.value}.',
        );
      }
      package[entry.key] = entry.value;
    }
  }
  final manifest = const JsonEncoder.withIndent('  ').convert(package);
  await target.parent.create(recursive: true);
  final staging = await target.parent.createTemp('.napi-package-');
  var published = false;
  try {
    for (final entry in files.entries) {
      await entry.value.copy('${staging.path}/${entry.key}');
    }
    if (native) await NativeRuntimeBundle.read(staging, built: true);
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

Future<Map<String, Object?>> _packageMetadata(
  Map<String, Object?> metadata,
) async {
  // Detach caller-owned nested data before any asynchronous name check.
  final package = (jsonDecode(jsonEncode(metadata)) as Map)
      .cast<String, Object?>();
  for (final field in _generatedFields) {
    if (package.containsKey(field)) {
      throw ArgumentError(
        'Package metadata "$field" conflicts with generated $field.',
      );
    }
  }
  final name = package['name'];
  // npm validates the whole unscoped name's initial character, while a scoped
  // leaf only forbids an initial period. Scopes retain encodeURIComponent's
  // unescaped ASCII characters; its special-character warning applies to the
  // leaf, not the scope.
  final unscoped = r'[a-z0-9][a-z0-9._-]*';
  final scope = r"[a-z0-9._~!()*'-]+";
  final leaf = r'[a-z0-9_-][a-z0-9._-]*';
  if (name is! String ||
      name.length > 214 ||
      !RegExp('^(?:$unscoped|@$scope/$leaf)\$').hasMatch(name) ||
      {'node_modules', 'favicon.ico'}.contains(name)) {
    throw ArgumentError('Invalid npm package name: $name');
  }
  if (!name.startsWith('@')) {
    // Query the installed Node runtime instead of freezing a built-in name list.
    final result = await Process.run('node', [
      '--input-type=module',
      '-e',
      "import {isBuiltin} from 'node:module'; "
          'process.exit(isBuiltin(process.argv[1]) ? 1 : 0);',
      '--',
      name,
    ]);
    if (result.exitCode == 1) {
      throw ArgumentError(
        'Package name "$name" shadows a Node built-in. Use a scoped name such as @scope/$name.',
      );
    }
    if (result.exitCode != 0) {
      throw StateError(
        'Cannot verify npm package name with Node: ${result.stderr}',
      );
    }
  }
  final version = package['version'];
  if (version is! String ||
      version.length > 256 ||
      !RegExp(
        r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
        r'(?:-(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
        r'(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?'
        r'(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
      ).hasMatch(version) ||
      version.split(RegExp(r'[-+]')).first.split('.').any((part) {
        final value = int.tryParse(part);
        return value == null || value > 9007199254740991;
      })) {
    throw ArgumentError('Invalid npm package version: $version');
  }
  return package;
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
