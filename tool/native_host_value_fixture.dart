import 'dart:convert';
import 'dart:io';

import 'package:napi/src/build/native_bundle.dart';
import 'package:napi/src/compiler/native/loader.dart';
import 'package:napi/src/compiler/sdk_adapter/dart_aot_adapter.dart';

import 'verify.dart' show run;

/// Fresh npm packaging of a handwritten private ABI fixture, not generated
/// opaque declarations. Uses the production carrier, bridge and AOT compiler.
Future<void> verifyNativeHostValues(
  Directory root, {
  required Directory nativeRuntime,
}) async {
  final canonical = await Directory(root.resolveSymbolicLinksSync())
      .createTemp('native host values 雪 ');
  final project = await Directory('${canonical.path}/fixture source').create();
  final package = await Directory('${project.path}/package').create();
  final bundle = await NativeRuntimeBundle.read(nativeRuntime);
  bundle.verifyHost();
  final source = await File('test/fixtures/native_host_values.dart')
      .copy('${project.path}/entrypoint.dart');
  await DartAotAdapter().compile(
    sourcePath: source.path,
    outputPath: '${package.path}/module.aot',
    packagesPath: File('.dart_tool/package_config.json').absolute.path,
  );
  await bundle.copyTo(package);
  await File('${package.path}/module.mjs').writeAsString(
    emitNativeLoader([
      'save',
      'get',
      'clear',
      'forget',
      'release',
      'readopt',
      'unpin',
      'wrongApi',
      'wrongEnv',
      'zoneSave',
      'zoneCount',
      'pressure',
      'churn',
      'releaseLater',
      'laterDone',
      'holdTimer',
      'HostRouter',
    ]),
  );
  await File('${package.path}/package.json').writeAsString(
    jsonEncode({
      'name': '@napi/native-host-values-fixture',
      'version': '0.0.0',
      'type': 'module',
      'exports': './module.mjs',
      'files': [
        '*.mjs',
        '*.aot',
        '*.node',
        '*.dylib',
        '*.json',
        '*LICENSE',
        'DART_AUTHORS',
      ],
    }),
  );
  await run('npm', ['pack', '--ignore-scripts', '--silent'], cwd: package.path);
  final archive = await File(
    '${package.path}/napi-native-host-values-fixture-0.0.0.tgz',
  ).copy('${canonical.path}/native-host-values.tgz');
  await project.delete(recursive: true);
  final consumer = await Directory('${canonical.path}/installed consumer 雪')
      .create();
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
  await File('test/integration/native_host_values.mjs')
      .copy('${consumer.path}/test.mjs');
  await run('node', ['--expose-gc', 'test.mjs'], cwd: consumer.path);
  stdout.writeln(
    'Native private host-value AOT fixture and fresh consumer: passed',
  );
}
