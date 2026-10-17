import 'dart:convert';
import 'dart:io';

import 'verify.dart' show run, typescript;

/// Exercises the native owner-thread event pump through a fresh npm consumer.
/// All exported declarations are synchronous; this does not expose Futures.
Future<void> verifyNativeEvents(
  Directory root, {
  required Directory nativeRuntime,
}) async {
  final canonical = await Directory(root.resolveSymbolicLinksSync())
      .createTemp('native events 雪 ');
  final project = await Directory('${canonical.path}/business 中文').create();
  await File('${project.path}/pubspec.yaml').writeAsString('''
name: native_events_business
environment:
  sdk: ^3.13.5
dependencies:
  napi:
    path: ${jsonEncode(Directory.current.path)}
''');
  await File('test/fixtures/native_events.dart')
      .copy('${project.path}/business.dart');
  await File('${project.path}/build.dart').writeAsString('''
import 'dart:io';
import 'package:napi/build.dart';
Future<void> main() async {
  await buildPackage(
    library: File('business.dart').absolute.uri,
    output: Directory('package'),
    metadata: {'name': '@napi/native-events-fixture', 'version': '0.0.0'},
    packagesPath: File('.dart_tool/package_config.json').absolute.path,
    target: BuildTarget.native,
    nativeRuntime: Directory(${jsonEncode(nativeRuntime.absolute.path)}),
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
    '${project.path}/package/napi-native-events-fixture-0.0.0.tgz',
  ).copy('${canonical.path}/native-events.tgz');
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
  await File('test/integration/native_events.mjs')
      .copy('${consumer.path}/test.mjs');
  await File('test/typescript/native_events.mts')
      .copy('${consumer.path}/consumer.mts');
  await run('node', ['--expose-gc', 'test.mjs'], cwd: consumer.path);
  await typescript(consumer, 'consumer.mts');
  stdout.writeln('Native event fresh package and TypeScript: passed');
}
