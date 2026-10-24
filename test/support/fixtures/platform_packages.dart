import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:napi/build.dart';

import '../commands.dart';
import '../consumer.dart';

/// CI builds native inputs on each host, then shares one npm archive between
/// native consumers. No Dart build runs in the consumer step.
Future<void> main(List<String> arguments) async {
  switch (arguments) {
    case ['build-native', final output]:
      final runtime = Platform.environment['NAPI_TEST_NATIVE_RUNTIME'];
      await buildLibrary(
        library: File('test/fixtures/platform_package.dart').absolute.uri,
        output: Directory(output),
        packagesPath: File('.dart_tool/package_config.json').absolute.path,
        target: BuildTarget.native,
        nativeRuntime: runtime == null ? null : Directory(runtime),
      );
    case ['assemble', final modules, final archive]:
      await consumer((temporary) async {
        final wasm = await buildLibrary(
          library: File('test/fixtures/platform_package.dart').absolute.uri,
          output: Directory('${temporary.path}/wasm'),
          packagesPath: File('.dart_tool/package_config.json').absolute.path,
        );
        final inputs = [
          for (final platform in [
            'macos-arm64',
            'macos-x64',
            'linux-x64-glibc',
            'linux-arm64-glibc',
            'windows-x64',
          ])
            BuiltModule(
              Directory('$modules/platform-module-$platform'),
              wasm.sdkVersion,
              target: BuildTarget.native,
            ),
          wasm,
        ];
        final package = await assemblePackage(
          modules: inputs,
          output: Directory('${temporary.path}/package'),
          metadata: {'name': '@napi/platform-fixture', 'version': '0.0.0'},
        );
        final result = await Process.run('npm', [
          'pack',
          '--ignore-scripts',
          '--json',
        ], workingDirectory: package.path);
        if (result.exitCode != 0) {
          throw StateError('npm pack failed: ${result.stdout}${result.stderr}');
        }
        final packed =
            (jsonDecode(result.stdout as String) as List).single
                as Map<String, dynamic>;
        final output = File(archive).absolute;
        await output.parent.create(recursive: true);
        await File('${package.path}/${packed['filename']}').copy(output.path);
        await assemblePackageSet(
          modules: inputs,
          output: Directory('${output.parent.path}/packages'),
          metadata: {'name': '@napi/platform-fixture', 'version': '0.0.0'},
        );
      });
    case ['consume', final archive]:
      await verifyPlatformPackage(File(archive).absolute);
    default:
      throw ArgumentError(
        'Expected build-native <output>, assemble <modules> <archive>, '
        'or consume <archive>.',
      );
  }
}

Future<void> verifyPlatformPackage(File archive) => consumer((root) async {
  final set = Directory('${archive.parent.path}/packages');
  await run('node', [
    File('test/integration/optional_platforms.mjs').absolute.path,
    set.path,
  ]);
  for (final node in nodeExecutables()) {
    final version = await Process.run(node, ['--version']);
    final installed = Directory(
      '${set.path}/consumer-${version.stdout.toString().trim()}',
    );
    await File('test/typescript/platform_commonjs.cts')
        .copy('${installed.path}/commonjs.cts');
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
      'commonjs.cts',
    ], cwd: installed.path);
  }
  final directory = await Directory('${root.path}/installed consumer 雪')
      .create();
  await File('${directory.path}/package.json')
      .writeAsString('{"private":true,"type":"module"}');
  await run('npm', [
    'install',
    '--offline',
    '--ignore-scripts',
    '--no-audit',
    '--no-fund',
    '--cache',
    '${root.path}/empty npm cache',
    archive.path,
  ], cwd: directory.path);
  final package = Directory(
    '${directory.path}/node_modules/@napi/platform-fixture',
  );
  for (final artifact in [
    'native/macos-arm64/module.aot',
    'native/macos-x64/module.aot',
    'native/linux-x64-glibc/module.aot',
    'native/linux-arm64-glibc/module.aot',
    'native/windows-x64/module.aot',
    'wasm/module.wasm',
  ]) {
    if (!await File('${package.path}/$artifact').exists()) {
      throw StateError('Installed package is missing $artifact.');
    }
  }
  await File('test/integration/platform_package.mjs')
      .copy('${directory.path}/test.mjs');
  await File('test/typescript/platform_package.mts')
      .copy('${directory.path}/consumer.mts');
  await File('test/integration/platform_commonjs.cjs')
      .copy('${directory.path}/commonjs.cjs');
  await File('test/typescript/platform_commonjs.cts')
      .copy('${directory.path}/commonjs.cts');
  for (final order in ['cjs-first', 'esm-first']) {
    await run('node', ['commonjs.cjs', order], cwd: directory.path);
  }
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
    'commonjs.cts',
  ], cwd: directory.path);
  await run('node', ['test.mjs'], cwd: directory.path);
  await typescript(directory, 'consumer.mts');

  final platform = switch (Abi.current()) {
    Abi.macosArm64 => 'macos-arm64',
    Abi.macosX64 => 'macos-x64',
    Abi.linuxX64 => 'linux-x64-glibc',
    Abi.linuxArm64 => 'linux-arm64-glibc',
    Abi.windowsX64 => 'windows-x64',
    final abi => throw UnsupportedError('Unsupported native platform: $abi'),
  };
  await File('${package.path}/native/$platform/module.aot').delete();
  await File('${directory.path}/broken.mjs').writeAsString('''
import assert from 'node:assert/strict';
await assert.rejects(import('@napi/platform-fixture'));
await assert.rejects(import('@napi/platform-fixture/native'));
const {Counter} = await import('@napi/platform-fixture/wasm');
assert.equal(new Counter().increment(), 2);
''');
  await run('node', ['broken.mjs'], cwd: directory.path);
});
