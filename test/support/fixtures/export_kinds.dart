import 'dart:io';

import 'package:napi/src/compiler/linker/dart_module_linker.dart';
import 'package:napi/src/compiler/emit/js/arguments.dart';
import 'package:napi/src/compiler/sdk_adapter/dart_sdk_adapter.dart';

/// Build the class and argument-presence Wasm regression fixture.
Future<Directory> buildExportKindFixture({
  required Directory output,
  String? dartExecutable,
  Directory? repositoryRoot,
}) async {
  final root = (repositoryRoot ?? Directory.current).absolute;
  final fixture = Directory('${root.path}/test/fixtures/export_kinds');
  await output.create();
  final entrypoint = File('${output.path}/fixture.dart');
  await File('${fixture.path}/fixture.dart.txt').copy(entrypoint.path);
  final compilation = await DartSdkAdapter(
    executable: dartExecutable,
  ).compile(sourcePath: entrypoint.path, outputPath: '${output.path}/raw.wasm');
  await File(compilation.sdkLicensePath).copy('${output.path}/DART_LICENSE');
  final linked = linkDartModule(
    rawWasmBytes: await File(compilation.wasmPath).readAsBytes(),
    rawMjsText: await File(compilation.jsPath).readAsString(),
    hostSpecifier: './dart_host.mjs',
    coreSpecifier: './core.wasm',
  );
  await File('${output.path}/core.wasm').writeAsBytes(linked.wasmBytes);
  await File('${output.path}/dart_host.mjs')
      .writeAsString(linked.hostJavaScript);
  await File('${output.path}/module.wasm').writeAsBytes(
    buildPublicWasmFacade(
      hostSpecifier: './public_api.mjs',
      exportNames: [
        'Counter',
        'requiredOpaque',
        'optionalOpaque',
        'optionalNumber',
      ],
    ),
  );
  await File('${fixture.path}/host.mjs').copy('${output.path}/public_api.mjs');
  await File('${output.path}/arguments.mjs').writeAsString(argumentPolicy);
  for (final name in [
    'test.mjs',
    'module.d.wasm.ts',
    'consumer.mts',
    'tsconfig.json',
  ]) {
    await File('${fixture.path}/$name').copy('${output.path}/$name');
  }
  final second = Directory('${output.path}/second');
  await second.create();
  for (final name in [
    'core.wasm',
    'dart_host.mjs',
    'module.wasm',
    'public_api.mjs',
    'DART_LICENSE',
    'arguments.mjs',
  ]) {
    await File('${output.path}/$name').copy('${second.path}/$name');
  }
  return output;
}
