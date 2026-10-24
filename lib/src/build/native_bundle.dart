import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import '../compiler/sdk_adapter/dart_sdk_adapter.dart';
import '../compiler/sdk_adapter/dart_aot_adapter.dart' show nativeSdkRevision;
import '../compiler/native/platform.dart';

/// A maintainer-built bundle. Reading never loads native code in the builder.
final class NativeRuntimeBundle {
  final Directory directory;
  final String identity;
  final String runtime;
  final NativePlatform platform;
  final Map<String, String> hashes;
  final String manifestJson;
  NativeRuntimeBundle._(
    this.directory,
    this.identity,
    this.runtime,
    this.platform,
    this.hashes,
    this.manifestJson,
  );

  static Future<NativeRuntimeBundle> read(
    Directory directory, {
    bool built = false,
    String? expectedManifestSha256,
  }) async {
    final root = directory.absolute;
    await checkNativePath(root.path);
    final manifestFile = File(
      '${root.path}/${built ? 'runtime.json' : 'manifest.json'}',
    );
    await _regular(manifestFile);
    final manifestBytes = await manifestFile.readAsBytes();
    if (expectedManifestSha256 != null &&
        sha256.convert(manifestBytes).toString() != expectedManifestSha256) {
      throw const FormatException(
        'Native runtime manifest integrity mismatch.',
      );
    }
    final Object? manifest;
    try {
      manifest = jsonDecode(utf8.decode(manifestBytes));
    } on FormatException {
      throw const FormatException('Invalid native runtime manifest JSON.');
    }
    final platform = manifest is Map<String, dynamic>
        ? NativePlatform.fromManifest(manifest)
        : null;
    if (manifest is! Map<String, dynamic> ||
        manifest['format'] != 1 ||
        manifest['sdkVersion'] != supportedDartSdkVersion ||
        manifest['sdkRevision'] != nativeSdkRevision ||
        platform == null ||
        manifest['abi'] != 15 ||
        manifest['bridge'] != 'bridge.node') {
      throw const SdkCompatibilityException(
        'NAPI_NATIVE_BUNDLE',
        'Expected a Dart 3.13.5 Product ABI 15 runtime bundle for macOS arm64/x64 or Linux arm64/x64 glibc.',
      );
    }
    final identity = manifest['identity'];
    final runtime = manifest['runtime'];
    final files = manifest['files'];
    if (identity is! String ||
        !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(identity) ||
        runtime is! String ||
        runtime != 'libnapi_runtime_$identity.${platform.runtimeExtension}' ||
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
      platform,
      Map.unmodifiable(hashes),
      jsonEncode(manifest),
    );
  }

  void verifyHost() => verifyNativeHost(expected: platform);

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

NativePlatform verifyNativeHost({NativePlatform? expected}) {
  final NativePlatform platform;
  if (Platform.isMacOS && Abi.current() == Abi.macosArm64) {
    platform = NativePlatform.macosArm64;
  } else if (Platform.isMacOS && Abi.current() == Abi.macosX64) {
    platform = NativePlatform.macosX64;
  } else if (Platform.isLinux &&
      (Abi.current() == Abi.linuxX64 || Abi.current() == Abi.linuxArm64)) {
    platform = Abi.current() == Abi.linuxX64
        ? NativePlatform.linuxX64
        : NativePlatform.linuxArm64;
    final version = _glibcVersion();
    if (version == null ||
        !nativeVersionAtLeast(version, platform.minimumLibcVersion!)) {
      throw SdkCompatibilityException(
        'NAPI_NATIVE_PLATFORM',
        'Native Linux builds require ${platform.description}.',
      );
    }
  } else {
    throw const SdkCompatibilityException(
      'NAPI_NATIVE_PLATFORM',
      'Native builds require macOS arm64/x64 or Linux arm64/x64 glibc.',
    );
  }
  if (expected != null && expected != platform) {
    throw SdkCompatibilityException(
      'NAPI_NATIVE_PLATFORM',
      'The native runtime requires ${expected.description}; this host is ${platform.description}.',
    );
  }
  return platform;
}

String? _glibcVersion() {
  try {
    final value = DynamicLibrary.process()
        .lookupFunction<Pointer<Uint8> Function(), Pointer<Uint8> Function()>(
          'gnu_get_libc_version',
        )();
    if (value == nullptr) return null;
    final bytes = <int>[];
    for (var index = 0; index < 64; index++) {
      final byte = value[index];
      if (byte == 0) return String.fromCharCodes(bytes);
      bytes.add(byte);
    }
  } on ArgumentError {
    // musl and other libc implementations do not export this glibc symbol.
    return null;
  }
  return null;
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
