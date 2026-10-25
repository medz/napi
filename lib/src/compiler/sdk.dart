import 'dart:io';

/// The official SDK used to compile Dart code for a matching native runtime.
final class DartSdk {
  DartSdk(this.directory);

  factory DartSdk.current() =>
      DartSdk(File(Platform.resolvedExecutable).parent.parent);

  final Directory directory;

  String get revision =>
      File('${directory.path}/revision').readAsStringSync().trim();

  String get version =>
      File('${directory.path}/version').readAsStringSync().trim();

  Future<void> compileAot({
    required File entry,
    required File output,
    String snapshotKind = 'app-aot-elf',
    String outputOption = '--elf',
    File? packageConfig,
  }) async {
    final kernel = File('${output.parent.path}/payload.dill');
    final executableSuffix = Platform.isWindows ? '.exe' : '';
    await _run('${directory.path}/bin/dartaotruntime$executableSuffix', [
      '${directory.path}/bin/snapshots/gen_kernel_aot.dart.snapshot',
      '--platform=${directory.path}/lib/_internal/vm_platform_product.dill',
      if (packageConfig != null) '--packages=${packageConfig.path}',
      '-Ddart.vm.product=true',
      '--aot',
      '--no-embed-sources',
      '--output=${kernel.path}',
      entry.path,
    ]);
    await _run('${directory.path}/bin/utils/gen_snapshot$executableSuffix', [
      '--snapshot_kind=$snapshotKind',
      '$outputOption=${output.path}',
      kernel.path,
    ]);
  }
}

Future<void> _run(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      '${result.stdout}${result.stderr}',
      result.exitCode,
    );
  }
}
