import 'dart:io';

import 'package:napi/build.dart';

import 'command.dart';
import 'verify.dart' show typescript;

/// Verify the same void-only package through both selectors and Node runtimes.
Future<void> verifyVoidFixture(
  Directory root, {
  Directory? nativeRuntime,
}) async {
  final native = nativeRuntime != null;
  final backend = native ? 'native' : 'wasm';
  final directory = await Directory(await root.resolveSymbolicLinks())
      .createTemp('void $backend 雪 ');
  final source = await File('test/fixtures/void_functions.dart')
      .copy('${directory.path}/business.dart');
  const functions = [
    'empty',
    'requiredValue',
    'optionalValue',
    'namedValue',
    'requiredNamed',
    'fail',
    'check',
    'numbers',
  ];
  final archives = <String>[];
  String? declarations;
  for (final external in [false, true]) {
    final name = external ? 'external' : 'fixture';
    final package = await buildPackage(
      library: source.uri,
      output: Directory('${directory.path}/$name'),
      metadata: {'name': '@napi/void-$name', 'version': '0.0.0'},
      packagesPath: File('.dart_tool/package_config.json').absolute.path,
      external: external
          ? ExternalLibrary([
              for (final name in functions) ExternalFunction(name),
            ])
          : null,
      target: native ? BuildTarget.native : BuildTarget.wasm,
      nativeRuntime: nativeRuntime,
    );
    final types = await File(
      '${package.path}/${native ? 'module.d.mts' : 'module.d.wasm.ts'}',
    ).readAsString();
    if (declarations != null && types != declarations) {
      throw StateError('Annotation and external void declarations differ.');
    }
    declarations = types;
    await run('npm', [
      'pack',
      '--ignore-scripts',
      '--silent',
      '--cache',
      '${directory.path}/npm cache',
    ], cwd: package.path);
    final archive = await File('${package.path}/napi-void-$name-0.0.0.tgz')
        .copy('${directory.path}/$name.tgz');
    archives.add(archive.path);
    await package.delete(recursive: true);
  }
  await source.delete();
  final consumer = await Directory('${directory.path}/installed consumer 雪')
      .create();
  await File('${consumer.path}/package.json')
      .writeAsString('{"private":true,"type":"module"}');
  await run('npm', [
    'install',
    '--offline',
    '--ignore-scripts',
    '--no-audit',
    '--no-fund',
    '--cache',
    '${directory.path}/npm cache',
    ...archives,
  ], cwd: consumer.path);
  await File('test/integration/void_functions.mjs')
      .copy('${consumer.path}/test.mjs');
  await File('${consumer.path}/consumer.mts').writeAsString(
    (await File('test/typescript/void_functions.mts').readAsString())
        .replaceAll('/BACKEND', native ? '/native' : '/module.wasm'),
  );
  await run('node', ['test.mjs'], cwd: consumer.path);
  await typescript(consumer, 'consumer.mts');
  stdout.writeln('Void $backend fresh packages and TypeScript: passed');
  stdout.writeln('Consumer: ${consumer.path}');
}

Future<void> main(List<String> args) async {
  if (args.length > 1) {
    throw ArgumentError(
      'Usage: dart run tool/void_fixture.dart [native-runtime-bundle]',
    );
  }
  await reportNodeVersions();
  final root = await Directory('.dart_tool').createTemp('napi void ');
  await verifyVoidFixture(
    root,
    nativeRuntime: args.isEmpty ? null : Directory(args.single),
  );
}
