import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import '../compiler/sdk_adapter/dart_sdk_adapter.dart';
import '../compiler/sdk_adapter/dart_aot_adapter.dart' show nativeSdkRevision;

/// A maintainer-built bundle. Reading never loads native code in the builder.
final class NativeRuntimeBundle {
  final Directory directory;
  final String identity;
  final String runtime;
  final Map<String, String> hashes;
  final String manifestJson;
  NativeRuntimeBundle._(
    this.directory,
    this.identity,
    this.runtime,
    this.hashes,
    this.manifestJson,
  );

  static Future<NativeRuntimeBundle> read(
    Directory directory, {
    bool built = false,
  }) async {
    final root = directory.absolute;
    await checkNativePath(root.path);
    final manifestFile = File(
      '${root.path}/${built ? 'runtime.json' : 'manifest.json'}',
    );
    await _regular(manifestFile);
    final Object? manifest;
    try {
      manifest = jsonDecode(await manifestFile.readAsString());
    } on FormatException {
      throw const FormatException('Invalid native runtime manifest JSON.');
    }
    if (manifest is! Map<String, dynamic> ||
        manifest['format'] != 1 ||
        manifest['sdkVersion'] != supportedDartSdkVersion ||
        manifest['sdkRevision'] != nativeSdkRevision ||
        manifest['platform'] != 'macos' ||
        manifest['architecture'] != 'arm64' ||
        manifest['minimumOsVersion'] != '14.0' ||
        manifest['abi'] != 11 ||
        manifest['bridge'] != 'bridge.node') {
      throw const SdkCompatibilityException(
        'NAPI_NATIVE_BUNDLE',
        'Expected a Dart 3.13.5 Product macOS arm64 ABI 11 runtime bundle.',
      );
    }
    final identity = manifest['identity'];
    final runtime = manifest['runtime'];
    final files = manifest['files'];
    if (identity is! String ||
        !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(identity) ||
        runtime is! String ||
        runtime != 'libnapi_runtime_$identity.dylib' ||
        files is! Map<String, dynamic>) {
      throw const FormatException('Invalid native runtime identity or files.');
    }
    final expected = {
      'bridge.node',
      runtime,
      'DART_LICENSE',
      'DART_AUTHORS',
      'NAPI_LICENSE',
    };
    if (files.length != expected.length || !expected.containsAll(files.keys)) {
      throw const FormatException('Unexpected native runtime bundle files.');
    }
    final hashes = <String, String>{};
    for (final name in expected) {
      final hash = files[name];
      if (hash is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
        throw FormatException('Invalid SHA-256 for $name.');
      }
      final file = File('${root.path}/$name');
      await _regular(file);
      if (await _hash(file) != hash) {
        throw FormatException(
          'Native runtime bundle integrity mismatch: $name',
        );
      }
      hashes[name] = hash;
    }
    return NativeRuntimeBundle._(
      root,
      identity,
      runtime,
      Map.unmodifiable(hashes),
      jsonEncode(manifest),
    );
  }

  void verifyHost() {
    if (!Platform.isMacOS || Abi.current() != Abi.macosArm64) {
      throw const SdkCompatibilityException(
        'NAPI_NATIVE_PLATFORM',
        'Native builds currently require macOS arm64; other targets are not yet supported.',
      );
    }
  }

  /// Verify the copied bytes too, so changing a bundle during a build cannot
  /// silently publish assets different from the validated manifest.
  Future<void> copyTo(Directory output) async {
    for (final entry in hashes.entries) {
      final source = File('${directory.path}/${entry.key}');
      await _regular(source);
      final copy = await source.copy('${output.path}/${entry.key}');
      if (await _hash(copy) != entry.value) {
        throw FormatException(
          'Native runtime changed during build: ${entry.key}',
        );
      }
    }
    await File('${output.path}/runtime.json').writeAsString(manifestJson);
  }
}

Future<String> _hash(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

Future<void> _regular(File file) async {
  await checkNativePath(file.absolute.path);
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw ArgumentError(
      'Native runtime input is not a regular file: ${file.path}',
    );
  }
}

Future<void> checkNativePath(String value) async {
  if (value.contains('\x00') || path.split(value).contains('..')) {
    throw ArgumentError(
      'Native paths must not contain NUL or traversal: $value',
    );
  }
  var current = path.rootPrefix(value);
  for (final segment in path.split(value).skip(1)) {
    current = path.join(current, segment);
    if (await FileSystemEntity.type(current, followLinks: false) ==
        FileSystemEntityType.link) {
      throw ArgumentError('Native paths must not contain symlinks: $current');
    }
  }
}
