import 'dart:io';

/// The private compiler ABI is deliberately restricted to one tested SDK.
const supportedDartSdkVersion = '3.13.5';

final class SdkCompatibilityException implements Exception {
  const SdkCompatibilityException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

final class DartWasmCompilation {
  const DartWasmCompilation({
    required this.wasmPath,
    required this.jsPath,
    required this.version,
    required this.sdkLicensePath,
  });

  final String wasmPath;
  final String jsPath;
  final String version;
  final String sdkLicensePath;
}

/// The only process boundary to dart2wasm's experimental, private interface.
///
/// The public `dart compile wasm` command does not expose Wasm export pragmas.
/// This adapter invokes the pinned SDK's compiler snapshot with its platform.
final class DartSdkAdapter {
  DartSdkAdapter({String? executable})
    : executable = executable ?? Platform.resolvedExecutable;

  final String executable;

  static void verifyVersionOutput(String output) {
    if (!RegExp(r'^Dart SDK version: 3\.13\.5 \(stable\)(?: |$)')
        .hasMatch(output.trim())) {
      throw SdkCompatibilityException(
        'NAPI_SDK_VERSION',
        'This experimental adapter requires Dart $supportedDartSdkVersion '
            'stable. Found: ${output.trim()}',
      );
    }
  }

  Future<DartWasmCompilation> compile({
    required String sourcePath,
    required String outputPath,
    String? packagesPath,
  }) async {
    final version = await Process.run(executable, ['--version']);
    final versionText = '${version.stdout}${version.stderr}'.trim();
    if (version.exitCode != 0) {
      throw SdkCompatibilityException(
        'NAPI_SDK_VERSION',
        'Could not identify the Dart SDK: $versionText',
      );
    }
    verifyVersionOutput(versionText);

    final dart = _resolveExecutable(executable);
    final bin = File(dart).parent;
    final runtime = File(
      '${bin.path}/${Platform.isWindows ? 'dartaotruntime.exe' : 'dartaotruntime'}',
    );
    final snapshot = File('${bin.path}/snapshots/dart2wasm_product.snapshot');
    final platform = File(
      '${bin.parent.path}/lib/_internal/dart2wasm_platform.dill',
    );
    final sdkLicense = File('${bin.parent.path}/LICENSE');
    for (final file in [runtime, snapshot, platform, sdkLicense]) {
      if (!file.existsSync()) {
        throw SdkCompatibilityException(
          'NAPI_SDK_LAYOUT',
          'Dart $supportedDartSdkVersion compiler component is missing: '
              '${file.path}',
        );
      }
    }
    if (!outputPath.endsWith('.wasm')) {
      throw ArgumentError.value(outputPath, 'outputPath', 'Must end in .wasm');
    }
    final output = File(outputPath).absolute;
    await output.parent.create(recursive: true);
    final result = await Process.run(runtime.path, [
      snapshot.path,
      '--platform=${platform.path}',
      '--enable-experimental-wasm-interop',
      '--no-source-maps',
      if (packagesPath != null)
        '--packages=${File(packagesPath).absolute.path}',
      File(sourcePath).absolute.path,
      output.path,
    ]);
    if (result.exitCode != 0) {
      throw SdkCompatibilityException(
        'NAPI_DART_COMPILATION',
        'dart2wasm failed (${result.exitCode}).\n'
            '${result.stdout}${result.stderr}',
      );
    }
    final jsPath = '${output.path.substring(0, output.path.length - 5)}.mjs';
    if (!await output.exists() || !await File(jsPath).exists()) {
      throw const SdkCompatibilityException(
        'NAPI_SDK_LAYOUT',
        'dart2wasm did not produce both the Wasm module and its host module.',
      );
    }
    return DartWasmCompilation(
      wasmPath: output.path,
      jsPath: jsPath,
      version: supportedDartSdkVersion,
      sdkLicensePath: sdkLicense.path,
    );
  }

  static String _resolveExecutable(String executable) {
    if (executable.contains('/') || executable.contains(r'\')) {
      return File(executable).resolveSymbolicLinksSync();
    }
    for (final directory in (Platform.environment['PATH'] ?? '').split(
      Platform.isWindows ? ';' : ':',
    )) {
      final candidate = File('$directory/$executable');
      if (candidate.existsSync()) return candidate.resolveSymbolicLinksSync();
    }
    throw const SdkCompatibilityException(
      'NAPI_SDK_LAYOUT',
      'Cannot locate the selected Dart executable in PATH.',
    );
  }
}
