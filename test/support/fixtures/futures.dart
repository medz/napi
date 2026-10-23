import 'dart:convert';
import 'dart:io';

import '../commands.dart' show run, typescript;

/// Runs the same Future contract against independently packed backend modules.
Future<void> verifyFutureFixture(
  Directory root, {
  Directory? nativeRuntime,
}) async {
  final native = nativeRuntime != null;
  final backend = native ? 'native' : 'wasm';
  final canonical = await Directory(root.resolveSymbolicLinksSync())
      .createTemp('futures $backend 雪 ');
  final project = await Directory('${canonical.path}/business 中文').create();
  await File('${project.path}/pubspec.yaml').writeAsString('''
name: futures_business
environment:
  sdk: ^3.13.5
dependencies:
  napi:
    path: ${jsonEncode(Directory.current.path)}
''');
  await File('test/fixtures/futures.dart')
      .copy('${project.path}/business.dart');
  await File('${project.path}/build.dart').writeAsString('''
import 'dart:io';
import 'package:napi/build.dart';
Future<void> main() async {
  await buildPackage(
    library: File('business.dart').absolute.uri,
    output: Directory('package'),
    metadata: {'name': '@napi/futures-fixture', 'version': '0.0.0'},
    packagesPath: File('.dart_tool/package_config.json').absolute.path,
    ${native ? 'target: BuildTarget.native,\n    nativeRuntime: Directory(${jsonEncode(nativeRuntime.absolute.path)}),' : ''}
  );
}
''');
  await run(Platform.resolvedExecutable, [
    'pub',
    'get',
    '--offline',
  ], cwd: project.path);
  await run(Platform.resolvedExecutable, [
    'run',
    'build.dart',
  ], cwd: project.path);
  await run('npm', [
    'pack',
    '--ignore-scripts',
    '--silent',
  ], cwd: '${project.path}/package');
  final archive = await File(
    '${project.path}/package/napi-futures-fixture-0.0.0.tgz',
  ).copy('${canonical.path}/futures.tgz');
  // Only the packed installation remains available to the consumer.
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
  await File('test/integration/futures.mjs').copy('${consumer.path}/test.mjs');
  final declarations = await File('test/typescript/futures.mts').readAsString();
  await File('${consumer.path}/consumer.mts').writeAsString(
    declarations.replaceAll('/BACKEND', native ? '/native' : '/module.wasm'),
  );
  await run('node', ['--expose-gc', 'test.mjs'], cwd: consumer.path);
  await typescript(consumer, 'consumer.mts');
}
