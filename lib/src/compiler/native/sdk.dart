import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../target.dart';

typedef _CompileNative =
    Int32 Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Pointer<Utf8>>,
    );
typedef _Compile =
    int Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Pointer<Utf8>>,
    );

/// Calls the complete compilation entry point in the bundled Dart SDK library.
final class NativeSdk {
  NativeSdk._(DynamicLibrary library)
    : _compile = library.lookupFunction<_CompileNative, _Compile>(
        'napi_compile',
      ),
      _free = library
          .lookupFunction<
            Void Function(Pointer<Utf8>),
            void Function(Pointer<Utf8>)
          >('napi_compiler_free');

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
    return NativeSdk._(DynamicLibrary.open(file.path));
  }

  void compile(NativeTarget target) {
    using((arena) {
      final error = arena<Pointer<Utf8>>();
      try {
        final status = _compile(
          target.entry.absolute.path.toNativeUtf8(allocator: arena),
          target.output.absolute.path.toNativeUtf8(allocator: arena),
          nullptr,
          target.node?.toNativeUtf8(allocator: arena) ?? nullptr,
          error,
        );
        if (status != 0) {
          throw StateError(
            error.value == nullptr
                ? 'Native compilation failed (status $status).'
                : error.value.toDartString(),
          );
        }
      } finally {
        if (error.value != nullptr) _free(error.value);
      }
    });
  }
}
