import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../target.dart';

typedef _CompileNative =
    Int32 Function(
      Pointer<_CompileOptions>,
      Pointer<Pointer<Utf8>>,
      Pointer<Pointer<Utf8>>,
    );
typedef _Compile =
    int Function(
      Pointer<_CompileOptions>,
      Pointer<Pointer<Utf8>>,
      Pointer<Pointer<Utf8>>,
    );

final class _CompileOptions extends Struct {
  external Pointer<Utf8> entry;
  external Pointer<Utf8> output;
  external Pointer<Utf8> packages;
  external Pointer<Utf8> node;
  external Pointer<Utf8> declarations;
}

/// Calls the complete compilation entry point in the bundled Dart SDK library.
final class NativeSdk {
  NativeSdk._(DynamicLibrary library, this.assets)
    : _compile = library.lookupFunction<_CompileNative, _Compile>(
        'napi_compile',
      ),
      _free = library
          .lookupFunction<
            Void Function(Pointer<Utf8>),
            void Function(Pointer<Utf8>)
          >('napi_compiler_free');

  final Directory assets;
  final _Compile _compile;
  final void Function(Pointer<Utf8>) _free;

  static Future<NativeSdk> current() async {
    final platform = switch (Abi.current()) {
      Abi.linuxArm64 => 'linux_arm64',
      Abi.linuxX64 => 'linux_x64',
      Abi.macosArm64 => 'macos_arm64',
      Abi.macosX64 => 'macos_x64',
      Abi.windowsArm64 => 'windows_arm64',
      Abi.windowsX64 => 'windows_x64',
      final abi => throw UnsupportedError('Unsupported native platform: $abi'),
    };
    final uri = await Isolate.resolvePackageUri(
      Uri.parse('package:napi/src/compiler/assets/$platform/'),
    );
    if (uri == null || uri.scheme != 'file') {
      throw StateError('Cannot locate the napi compiler library.');
    }
    final extension = Platform.isWindows
        ? 'dll'
        : Platform.isMacOS
        ? 'dylib'
        : 'so';
    final file = File.fromUri(uri.resolve('compiler.$extension'));
    if (!file.existsSync()) {
      throw UnsupportedError('No bundled napi compiler for $platform.');
    }
    final manifest = jsonDecode(
      await File.fromUri(uri.resolve('manifest.json')).readAsString(),
    );
    if (manifest is! Map ||
        manifest['abi'] != 2 ||
        manifest['platform'] != platform) {
      throw StateError('Incompatible bundled napi compiler for $platform.');
    }
    return NativeSdk._(DynamicLibrary.open(file.path), Directory.fromUri(uri));
  }

  Map<String, Object?>? compile(
    NativeTarget target, {
    bool metadata = false,
  }) => using((arena) {
    final error = arena<Pointer<Utf8>>();
    final report = arena<Pointer<Utf8>>();
    try {
      final options = arena<_CompileOptions>();
      options.ref
        ..entry = target.entry.absolute.path.toNativeUtf8(allocator: arena)
        ..output = target.output.absolute.path.toNativeUtf8(allocator: arena)
        ..packages = nullptr
        ..node = target.node?.toNativeUtf8(allocator: arena) ?? nullptr
        ..declarations =
            target.declarations?.absolute.path.toNativeUtf8(allocator: arena) ??
            nullptr;
      final status = _compile(options, metadata ? report : nullptr, error);
      if (status != 0) {
        throw StateError(
          error.value == nullptr
              ? 'Native compilation failed (status $status).'
              : error.value.toDartString(),
        );
      }
      if (!metadata) return null;
      if (report.value == nullptr) {
        throw StateError('The compiler did not return export metadata.');
      }
      return Map<String, Object?>.from(
        jsonDecode(report.value.toDartString()) as Map,
      );
    } finally {
      if (error.value != nullptr) _free(error.value);
      if (report.value != nullptr) _free(report.value);
    }
  });
}
