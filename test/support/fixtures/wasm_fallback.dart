import 'dart:io';

import 'package:napi/build.dart';

import '../commands.dart';

Future<void> verifyWasmFallback(Directory root, Directory runtime) async {
  final package = await PackageBuild(
    library: File('test/fixtures/platform_package.dart').absolute.uri,
    output: Directory('${root.path}/package'),
    name: '@napi/fallback-fixture',
    version: '0.0.0',
    packagesPath: File('.dart_tool/package_config.json').absolute.path,
    target: BuildTarget.native,
    targets: {BuildTarget.native, BuildTarget.wasm},
    wasmFallback: true,
    nativeRuntime: runtime,
  ).build();
  await run('npm', ['pack', '--ignore-scripts', '--silent'], cwd: package.path);
  final archive = await File('${package.path}/napi-fallback-fixture-0.0.0.tgz')
      .copy('${root.path}/package.tgz');
  await package.delete(recursive: true);
  final consumer = await Directory('${root.path}/consumer').create();
  await File('${consumer.path}/package.json')
      .writeAsString('{"private":true,"type":"module"}');
  await run('npm', [
    'install',
    '--offline',
    '--ignore-scripts',
    '--no-audit',
    '--no-fund',
    archive.path,
  ], cwd: consumer.path);
  await File('test/integration/wasm_fallback.mjs')
      .copy('${consumer.path}/test.mjs');
  for (final mode in [
    'esm-first',
    'cjs-first',
    'unsupported',
    'missing',
    'broken',
  ]) {
    await run('node', ['test.mjs', mode], cwd: consumer.path);
  }
  await File('test/typescript/wasm_fallback.mts')
      .copy('${consumer.path}/consumer.mts');
  await File('test/typescript/wasm_fallback.cts')
      .copy('${consumer.path}/consumer.cts');
  await typecheck([
    '--ignoreConfig',
    '--strict',
    '--noEmit',
    '--target',
    'ES2022',
    '--module',
    'NodeNext',
    '--moduleResolution',
    'NodeNext',
    'consumer.mts',
    'consumer.cts',
  ], cwd: consumer.path);
}
