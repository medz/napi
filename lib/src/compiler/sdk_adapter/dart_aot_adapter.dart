import 'dart:io';

import 'dart_sdk_adapter.dart';

const nativeSdkRevision = '04bcd1036cdc799ac6564988f159ee454d42c822';

/// Uses the ordinary SDK; no C compiler or SDK source checkout is needed.
final class DartAotAdapter {
  final String executable;
  DartAotAdapter({String? executable})
    : executable = executable ?? Platform.resolvedExecutable;

  Future<void> compile({
    required String sourcePath,
    required String outputPath,
    String? packagesPath,
  }) async {
    final version = await Process.run(executable, ['--version']);
    final versionText = '${version.stdout}${version.stderr}'.trim();
    if (version.exitCode != 0) {
      throw SdkCompatibilityException('NAPI_SDK_VERSION', versionText);
    }
    DartSdkAdapter.verifyVersionOutput(versionText);
    final binary = DartSdkAdapter.resolveExecutable(executable);
    final revision = File('${File(binary).parent.parent.path}/revision');
    if (!revision.existsSync() ||
        revision.readAsStringSync().trim() != nativeSdkRevision) {
      throw const SdkCompatibilityException(
        'NAPI_SDK_VERSION',
        'Native compilation requires the exact Dart 3.13.5 stable SDK revision.',
      );
    }
    final source = File(sourcePath).absolute;
    final output = File(outputPath).absolute;
    final packages = packagesPath == null ? null : File(packagesPath).absolute;
    final result = Platform.isWindows
        ? await _compileWindows(File(binary).parent, source, output, packages)
        : await Process.run(binary, [
            'compile',
            'aot-snapshot',
            if (packages != null) '--packages=${packages.path}',
            '--output=${output.path}',
            source.path,
          ]);
    if (result.exitCode != 0 || !File(outputPath).existsSync()) {
      throw SdkCompatibilityException(
        'NAPI_DART_COMPILATION',
        'Dart AOT compilation failed (${result.exitCode}).\n${result.stdout}${result.stderr}',
      );
    }
  }

  Future<ProcessResult> _compileWindows(
    Directory bin,
    File source,
    File output,
    File? packages,
  ) async {
    final runtime = File('${bin.path}/dartaotruntime.exe');
    final kernel = File('${bin.path}/snapshots/gen_kernel_aot.dart.snapshot');
    final platform = File(
      '${bin.parent.path}/lib/_internal/vm_platform_product.dill',
    );
    final snapshot = File('${bin.path}/utils/gen_snapshot.exe');
    for (final file in [runtime, kernel, platform, snapshot]) {
      if (!file.existsSync()) {
        throw SdkCompatibilityException(
          'NAPI_SDK_LAYOUT',
          'Dart $supportedDartSdkVersion compiler component is missing: ${file.path}',
        );
      }
    }
    final temporary = await output.parent.createTemp('.napi-aot-');
    try {
      // The pinned Windows gen_snapshot uses ANSI argv. Keep its file arguments
      // relative and ASCII; the Dart frontend still reads the original Unicode
      // source/package paths, and CreateProcessW preserves the working directory.
      final generated = await Process.run(runtime.path, [
        kernel.path,
        '--platform=${platform.path}',
        '-Ddart.vm.product=true',
        '-Ddart.vm.asan=false',
        '-Ddart.vm.msan=false',
        '-Ddart.vm.tsan=false',
        '--target-os=windows',
        '--aot',
        '--no-embed-sources',
        if (packages != null) '--packages=${packages.path}',
        '--output=program.dill',
        '--invocation-modes=compile',
        source.path,
      ], workingDirectory: temporary.path);
      if (generated.exitCode != 0) return generated;
      final result = await Process.run(snapshot.path, [
        '--snapshot-kind=app-aot-elf',
        '--elf=module.aot',
        'program.dill',
      ], workingDirectory: temporary.path);
      if (result.exitCode == 0) {
        await File('${temporary.path}/module.aot').rename(output.path);
      }
      return result;
    } finally {
      await temporary.delete(recursive: true);
    }
  }
}
