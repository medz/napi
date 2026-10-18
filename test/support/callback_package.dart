import 'dart:convert';
import 'dart:io';

import '../../tool/command.dart' show run;

/// Build source/external callbacks once, then relocate and install both archives.
/// Compiler/npm subprocess trees still use the existing build command path.
Future<Directory> buildCallbackPackage(
  Directory root, {
  Directory? nativeRuntime,
}) async {
  final native = nativeRuntime != null;
  final backend = native ? 'native' : 'wasm';
  final canonical = await Directory(root.resolveSymbolicLinksSync())
      .createTemp('callback $backend 雪 ');
  final project = await Directory('${canonical.path}/business 中文').create();
  await File('${project.path}/pubspec.yaml').writeAsString('''
name: callback_business
environment:
  sdk: ^3.13.5
dependencies:
  napi:
    path: ${jsonEncode(Directory.current.path)}
''');
  await File('test/fixtures/callbacks.dart')
      .copy('${project.path}/business.dart');
  await File('${project.path}/build.dart').writeAsString('''
import 'dart:io';
import 'package:napi/build.dart';
import 'package:napi/napi.dart';
Future<void> main() async {
  for (final external in [false, true]) {
    await buildPackage(
      library: File('business.dart').absolute.uri,
      output: Directory(external ? 'external' : 'package'),
      metadata: {'name': external ? '@napi/callback-external' : '@napi/callback-fixture', 'version': '0.0.0'},
      packagesPath: File('.dart_tool/package_config.json').absolute.path,
      external: external ? const ExternalLibrary([
        ExternalFunction('plainCallback'),
        ExternalFunction('plainAsyncCallback'),
        ExternalFunction('callHandle'),
        ExternalFunction('readCallbackHandle'),
        ExternalFunction('clearCallbackHandle'),
        ExternalFunction('callHandles'),
        ExternalFunction('callNullableHandle'),
        ExternalFunction('callAsyncHandle'),
        ExternalFunction('callWideHandle', config: NAPI(bigint: true)),
        ExternalFunction('sameHandleSignature'),
        ExternalFunction('sameWideHandleSignature', config: NAPI(bigint: true)),
        ExternalFunction('sameOpaqueHandleSignature'),
        ExternalFunction('callPayloadHandles'),
        ExternalFunction('callbackHandleOrder', config: NAPI(bigint: true)),
        ExternalFunction('callbackPressure'),
      ]) : null,
      ${native ? 'target: BuildTarget.native,\n      nativeRuntime: Directory(${jsonEncode(nativeRuntime.absolute.path)}),' : ''}
    );
  }
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
  final archives = <String>[];
  for (final (directory, name) in [
    ('package', 'fixture'),
    ('external', 'external'),
  ]) {
    final package = '${project.path}/$directory';
    await run('npm', ['pack', '--ignore-scripts', '--silent'], cwd: package);
    final archive = await File('$package/napi-callback-$name-0.0.0.tgz')
        .copy('${canonical.path}/$name.tgz');
    archives.add(archive.path);
  }
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
    ...archives,
  ], cwd: consumer.path);
  await File('test/integration/callbacks.mjs')
      .copy('${consumer.path}/test.mjs');
  final declarations = await File('test/typescript/callbacks.mts')
      .readAsString();
  await File('${consumer.path}/consumer.mts').writeAsString(
    declarations.replaceAll('/BACKEND', native ? '/native' : '/module.wasm'),
  );
  return consumer;
}
