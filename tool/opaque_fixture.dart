import 'dart:convert';
import 'dart:io';

import 'verify.dart' show run;

/// Verifies generated opaque declarations in relocated, installed packages.
Future<void> verifyOpaqueFixture(
  Directory root, {
  Directory? nativeRuntime,
}) async {
  final native = nativeRuntime != null;
  final backend = native ? 'native' : 'wasm';
  final canonical = await Directory(root.resolveSymbolicLinksSync())
      .createTemp('opaque $backend 雪 ');
  final project = await Directory('${canonical.path}/business 中文').create();
  await File('${project.path}/pubspec.yaml').writeAsString('''
name: opaque_business
environment:
  sdk: ^3.13.5
dependencies:
  napi:
    path: ${jsonEncode(Directory.current.path)}
''');
  await File('test/fixtures/opaque.dart').copy('${project.path}/business.dart');
  await File('${project.path}/build.dart').writeAsString('''
import 'dart:io';
import 'package:napi/build.dart';
Future<void> main() async {
  for (final external in [false, true]) {
    await buildPackage(
      library: File('business.dart').absolute.uri,
      output: Directory(external ? 'external' : 'package'),
      metadata: {'name': external ? '@napi/opaque-external' : '@napi/opaque-fixture', 'version': '0.0.0'},
      packagesPath: File('.dart_tool/package_config.json').absolute.path,
      external: external ? const ExternalLibrary([
        ExternalFunction('plainEcho'),
        ExternalClass('PlainStore'),
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
    final archive = await File('$package/napi-opaque-$name-0.0.0.tgz')
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
  await File('test/integration/opaque.mjs').copy('${consumer.path}/test.mjs');
  final declarations = await File('test/typescript/opaque.mts').readAsString();
  await File('${consumer.path}/consumer.mts').writeAsString(
    declarations.replaceAll('/BACKEND', native ? '/native' : '/module.wasm'),
  );
  await run('node', ['--expose-gc', 'test.mjs'], cwd: consumer.path);
  final tsc =
      Platform.environment['NAPI_TSC'] ??
      '${Directory.current.path}/.dart_tool/js/node_modules/typescript/bin/tsc';
  for (final mode in ['NodeNext', 'Bundler']) {
    for (final exact in ['true', 'false']) {
      for (final strictFunctions in ['true', 'false']) {
        await run('node', [
          File(tsc).absolute.path,
          '--ignoreConfig',
          '--strict',
          '--exactOptionalPropertyTypes',
          exact,
          '--strictFunctionTypes',
          strictFunctions,
          '--noEmit',
          '--target',
          'ES2022',
          '--module',
          mode == 'NodeNext' ? 'NodeNext' : 'ESNext',
          '--moduleResolution',
          mode,
          '--allowArbitraryExtensions',
          'consumer.mts',
        ], cwd: consumer.path);
      }
    }
  }
  stdout.writeln('Opaque $backend fresh packages and TypeScript: passed');
}

Future<void> main(List<String> args) async {
  if (args.length > 1) {
    throw ArgumentError(
      'Usage: dart run tool/opaque_fixture.dart [native-runtime-bundle]',
    );
  }
  final root = await Directory('.dart_tool').createTemp('napi opaque ');
  stdout.writeln('Opaque verification artifacts: ${root.absolute.path}');
  await verifyOpaqueFixture(
    root,
    nativeRuntime: args.isEmpty ? null : Directory(args.single),
  );
}
