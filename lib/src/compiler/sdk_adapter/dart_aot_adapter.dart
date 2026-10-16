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
    final result = await Process.run(binary, [
      'compile',
      'aot-snapshot',
      if (packagesPath != null)
        '--packages=${File(packagesPath).absolute.path}',
      '--output=${File(outputPath).absolute.path}',
      File(sourcePath).absolute.path,
    ]);
    if (result.exitCode != 0 || !File(outputPath).existsSync()) {
      throw SdkCompatibilityException(
        'NAPI_DART_COMPILATION',
        'Dart AOT compilation failed (${result.exitCode}).\n${result.stdout}${result.stderr}',
      );
    }
  }
}
