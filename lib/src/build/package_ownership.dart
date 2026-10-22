import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import 'metadata.dart';
import 'native_bundle.dart';
import 'publish.dart';

const packageOwnershipFile = '.napi-output.json';
const wasmPackageFiles = [
  'module.wasm',
  'module.d.wasm.ts',
  'host.mjs',
  'boundary.mjs',
  'DART_LICENSE',
];
const wasmCallFiles = ['core.wasm', 'calls.mjs', 'references.mjs'];
const packageAssetNames = {
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

/// The only generated package layouts that may authorize replacing old bytes.
Set<String> packageArtifactNames(
  Set<String> targets,
  String? runtime, {
  required bool calls,
}) {
  final dual = targets.length > 1;
  return {
    for (final target in targets)
      for (final name
          in target == 'wasm'
              ? [...wasmPackageFiles, if (calls) ...wasmCallFiles]
              : [
                  'module.mjs',
                  'module.d.mts',
                  'module.aot',
                  'runtime.json',
                  'bridge.node',
                  runtime!,
                  'DART_LICENSE',
                  'DART_AUTHORS',
                  'NAPI_LICENSE',
                ])
        '${dual ? '$target/' : ''}$name',
  };
}

Map<String, Object?> packageEntrypoints(Set<String> targets, String root) {
  Map<String, String> entry(String target) {
    final prefix = targets.length > 1 ? './$target/' : './';
    return {
      'types':
          '$prefix${target == 'native' ? 'module.d.mts' : 'module.d.wasm.ts'}',
      'import': '$prefix${target == 'native' ? 'module.mjs' : 'module.wasm'}',
    };
  }

  return {
    '.': entry(root),
    if (targets.contains('native')) './native': entry('native'),
    if (targets.length > 1) './wasm': entry('wasm'),
    if (targets.contains('wasm')) './module.wasm': entry('wasm'),
  };
}

/// Package-local bookkeeping, not a general output ownership mechanism.
/// No manifest supplied by an author can claim paths outside known layouts.
final class PackageOwnership {
  PackageOwnership._(
    this.directory,
    this._entries,
    this.artifacts,
    this.assets,
    this.metadata,
  );

  final Directory directory;
  final Map<String, _Entry> _entries;
  final Set<String> artifacts;
  final Set<String> assets;
  final Map<String, Object?> metadata;

  static Future<PackageOwnership?> read(Directory directory) async {
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.directory) {
      throw ArgumentError(
        'Package output is not a managed directory: ${directory.path}',
      );
    }
    final marker = File('${directory.path}/$packageOwnershipFile');
    if (await FileSystemEntity.type(marker.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw ArgumentError(
        'Existing output has no package ownership manifest: ${directory.path}',
      );
    }
    final manifest = await _json(marker, ownership: true);
    if (manifest['format'] != 1 || manifest['kind'] != 'napi-package') {
      throw const FormatException('Unsupported package ownership manifest.');
    }
    final targets = _names(manifest['targets']);
    final root = manifest['root'];
    final runtime = manifest['runtime'];
    final calls = manifest['calls'];
    final assets = _names(manifest['assets']);
    final auto = _names(manifest['autoPlatform']);
    final hashes = manifest['artifacts'];
    if (targets.isEmpty ||
        !{'wasm', 'native'}.containsAll(targets) ||
        !targets.contains(root) ||
        calls is! bool ||
        (calls && !targets.contains('wasm')) ||
        !packageAssetNames.containsAll(assets) ||
        !{'os', 'cpu'}.containsAll(auto) ||
        (auto.isNotEmpty && (targets.length != 1 || root != 'native')) ||
        (targets.contains('native')
            ? runtime is! String ||
                  !RegExp(r'^libnapi_runtime_[A-Za-z0-9_.-]+\.dylib$')
                      .hasMatch(runtime)
            : runtime != null) ||
        hashes is! Map<String, dynamic>) {
      throw const FormatException('Invalid package ownership layout.');
    }
    final artifacts = packageArtifactNames(
      targets,
      runtime as String?,
      calls: calls,
    );
    if (hashes.length != artifacts.length ||
        !artifacts.containsAll(hashes.keys)) {
      throw const FormatException(
        'Ownership may only claim known package artifacts.',
      );
    }
    final entries = await _scan(directory);
    for (final name in artifacts) {
      final hash = hashes[name];
      if (hash is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
          entries[name]?.hash != hash) {
        throw ArgumentError('Generated package artifact changed: $name');
      }
    }
    if (targets.contains('native')) {
      final bundle = await NativeRuntimeBundle.read(
        targets.length > 1 ? Directory('${directory.path}/native') : directory,
        built: true,
      );
      if (bundle.runtime != runtime) {
        throw const FormatException(
          'Native ownership does not match runtime.json.',
        );
      }
    }
    for (final name in assets) {
      if (entries[name]?.hash == null) {
        throw ArgumentError(
          'Selected package asset is no longer a file: $name',
        );
      }
    }
    final package = await _json(File('${directory.path}/package.json'));
    final files = _names(package['files']);
    if (files.length != artifacts.length + assets.length ||
        !files.containsAll({...artifacts, ...assets}) ||
        package['type'] != 'module' ||
        !_sameJson(
          package['exports'],
          packageEntrypoints(targets, root as String),
        )) {
      throw ArgumentError(
        'Generated package metadata changed: type, files or exports.',
      );
    }
    for (final field in generatedPackageFields) {
      if (!{'type', 'files', 'exports'}.contains(field) &&
          package.containsKey(field)) {
        throw ArgumentError(
          'Package metadata "$field" conflicts with generated $field.',
        );
      }
      package.remove(field);
    }
    for (final field in auto) {
      if (!_sameJson(package[field], [field == 'os' ? 'darwin' : 'arm64'])) {
        throw ArgumentError('Generated package metadata changed: $field');
      }
      package.remove(field);
    }
    // Also validates author metadata edited since the previous build.
    packageMetadata(package);
    return PackageOwnership._(directory, entries, artifacts, assets, package);
  }

  Future<void> copyAuthors(
    Directory staging,
    Set<String> newArtifacts, {
    Set<String> replacedAssets = const {},
  }) async {
    for (final entry in _entries.entries) {
      final name = entry.key;
      if (name.isEmpty ||
          artifacts.contains(name) ||
          name == packageOwnershipFile) {
        continue;
      }
      final destination = path.join(staging.path, name);
      if (entry.value.hash == null) {
        await Directory(destination).create(recursive: true);
      } else {
        // Linux restores package.json metadata after rewriting its contents.
        // Explicitly replaced assets should receive a fresh destination inode.
        if ((name == 'package.json' && Platform.isLinux) ||
            (assets.contains(name) && replacedAssets.contains(name))) {
          continue;
        }
        await File(destination).parent.create(recursive: true);
        // macOS File.copy preserves metadata of the rewritten package.json.
        await File(path.join(directory.path, name)).copy(destination);
      }
    }
    // Only author entries are present now. Ask the same filesystem which names
    // collide: textual comparisons miss case/Unicode-equivalent names on APFS.
    for (final name in newArtifacts) {
      if (await FileSystemEntity.type(
            path.join(staging.path, name),
            followLinks: false,
          ) !=
          FileSystemEntityType.notFound) {
        throw ArgumentError(
          'Generated artifact conflicts with author content: $name',
        );
      }
      for (
        var parent = path.dirname(name);
        parent != '.';
        parent = path.dirname(parent)
      ) {
        final type = await FileSystemEntity.type(
          path.join(staging.path, parent),
          followLinks: false,
        );
        if (type != FileSystemEntityType.notFound &&
            type != FileSystemEntityType.directory) {
          throw ArgumentError(
            'Generated artifact parent conflicts with author content: $parent',
          );
        }
      }
    }
  }

  Future<void> checkUnchanged() async {
    final current = await _scan(directory);
    if (_entries.length != current.length ||
        _entries.entries.any((entry) {
          final before = entry.value;
          final after = current[entry.key];
          // Our own hashing and directory traversal can advance access times.
          return after == null ||
              before.hash != after.hash ||
              before.mode != after.mode ||
              before.size != after.size ||
              before.modified != after.modified ||
              before.changed != after.changed;
        })) {
      throw FileSystemException(
        'Package output changed during rebuild.',
        directory.path,
      );
    }
  }

  /// Restore retained metadata after writes, with directories after children.
  void copyMetadata(Directory staging, {required Set<String> replacedFiles}) {
    for (final entry in _entries.entries.toList().reversed) {
      if (entry.value.hash == null) {
        copyPackageDirectoryMetadata(
          Directory(path.join(directory.path, entry.key)),
          Directory(path.join(staging.path, entry.key)),
          accessTime: entry.value.accessed,
        );
      } else if (!artifacts.contains(entry.key) &&
          entry.key != packageOwnershipFile &&
          !replacedFiles.contains(entry.key)) {
        copyPackageFileMetadata(
          File(path.join(directory.path, entry.key)),
          File(path.join(staging.path, entry.key)),
          preserveTimes: entry.key != 'package.json',
          accessTime: entry.value.accessed,
        );
      }
    }
  }
}

Future<void> writePackageOwnership(
  Directory staging, {
  required Set<String> targets,
  required String root,
  required String? runtime,
  required bool calls,
  required Set<String> assets,
  required Set<String> autoPlatform,
}) async {
  final names = packageArtifactNames(targets, runtime, calls: calls);
  final hashes = <String, String>{};
  for (final name in names) {
    hashes[name] = await _hash(File(path.join(staging.path, name)));
  }
  await File('${staging.path}/$packageOwnershipFile').writeAsString(
    '${const JsonEncoder.withIndent('  ').convert({'format': 1, 'kind': 'napi-package', 'targets': targets.toList(), 'root': root, 'runtime': runtime, 'calls': calls, 'artifacts': hashes, 'assets': assets.toList(), 'autoPlatform': autoPlatform.toList()})}\n',
  );
}

Future<Map<String, dynamic>> _json(File file, {bool ownership = false}) async {
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw ArgumentError('Package metadata is not a regular file: ${file.path}');
  }
  final String text;
  if (ownership) {
    final input = await file.open();
    final List<int> bytes;
    try {
      bytes = await input.read(1024 * 1024 + 1);
    } finally {
      await input.close();
    }
    if (bytes.length > 1024 * 1024) {
      throw const FormatException('Package ownership exceeds 1 MiB.');
    }
    text = utf8.decode(bytes);
  } else {
    // Author package metadata has the same JSON domain as the public input.
    // Only our small private ownership record carries a fixed byte limit.
    text = await file.readAsString();
  }
  final value = jsonDecode(text);
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Expected package metadata object.');
  }
  return value;
}

Set<String> _names(Object? value) {
  if (value is! List ||
      value.any((item) => item is! String) ||
      value.toSet().length != value.length) {
    throw const FormatException('Expected distinct package names.');
  }
  return value.cast<String>().toSet();
}

bool _sameJson(Object? left, Object? right) {
  if (left is Map && right is Map) {
    return left.length == right.length &&
        left.keys.every(
          (key) => right.containsKey(key) && _sameJson(left[key], right[key]),
        );
  }
  if (left is List && right is List) {
    return left.length == right.length &&
        List.generate(
          left.length,
          (index) => _sameJson(left[index], right[index]),
        ).every((same) => same);
  }
  return left == right;
}

typedef _Entry = ({
  String? hash,
  int mode,
  int size,
  DateTime modified,
  DateTime changed,
  PackageAccessTime? accessed,
});

Future<Map<String, _Entry>> _scan(Directory directory) async {
  final result = <String, _Entry>{};
  Future<void> visit(FileSystemEntity entity) async {
    final type = await FileSystemEntity.type(entity.path, followLinks: false);
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.directory) {
      throw ArgumentError(
        'Managed packages cannot contain links or special files: ${entity.path}',
      );
    }
    // Capture before reading a file or listing this directory's children.
    final accessed = packageAccessTime(entity);
    final stat = await entity.stat();
    final name = path.equals(entity.path, directory.path)
        ? ''
        : path.relative(entity.path, from: directory.path);
    result[name] = (
      hash: type == FileSystemEntityType.file
          ? await _hash(File(entity.path))
          : null,
      mode: stat.mode,
      size: stat.size,
      modified: stat.modified,
      changed: stat.changed,
      accessed: accessed,
    );
    if (type == FileSystemEntityType.directory) {
      await for (final child in Directory(
        entity.path,
      ).list(followLinks: false)) {
        await visit(child);
      }
    }
  }

  await visit(directory);
  return result;
}

Future<String> _hash(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();
