import 'dart:convert';
import 'dart:io';

import 'export_kind_fixture.dart';
import 'scalar_fixture.dart';
import 'argument_fixture.dart';
import 'structural_fixture.dart';
import 'package_assembly_fixture.dart';
import 'class_fixture.dart';

Future<void> run(String command, List<String> args, {String? cwd}) async {
  final result = await Process.run(command, args, workingDirectory: cwd);
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) {
    throw StateError('$command ${args.join(' ')} exited ${result.exitCode}');
  }
}

Future<void> typescript(Directory directory, String consumer) async {
  final tsc =
      Platform.environment['NAPI_TSC'] ??
      '${Directory.current.path}/.dart_tool/js/node_modules/typescript/bin/tsc';
  if (!File(tsc).existsSync()) {
    throw StateError(
      'Install TypeScript 7.0.2 under .dart_tool/js, or set NAPI_TSC.',
    );
  }
  for (final mode in ['NodeNext', 'Bundler']) {
    await run('node', [
      File(tsc).absolute.path,
      '--ignoreConfig',
      '--strict',
      '--exactOptionalPropertyTypes',
      '--noEmit',
      '--target',
      'ES2022',
      '--module',
      mode == 'NodeNext' ? 'NodeNext' : 'ESNext',
      '--moduleResolution',
      mode,
      '--allowArbitraryExtensions',
      consumer,
    ], cwd: directory.path);
  }
}

Future<void> installedConsumer(
  Directory scalar,
  Directory root, {
  String fixture = 'package',
}) async {
  // This handwritten package tests the foundation's contract. Production npm
  // metadata generation, naming, assets and rebuild safety belong to #134/135.
  await File('${scalar.path}/package.json').writeAsString(
    jsonEncode({
      'name': '@napi/foundation-fixture',
      'version': '0.0.0',
      'type': 'module',
      'files': [
        for (final name in [
          'module.wasm',
          'core.wasm',
          'calls.mjs',
          'module.d.wasm.ts',
          'host.mjs',
          'boundary.mjs',
          'DART_LICENSE',
        ])
          if (File('${scalar.path}/$name').existsSync()) name,
      ],
      'exports': {
        for (final key in ['.', './module.wasm'])
          key: {'types': './module.d.wasm.ts', 'import': './module.wasm'},
      },
    }),
  );
  await run('npm', ['pack', '--ignore-scripts', '--silent'], cwd: scalar.path);
  final consumer = await Directory('${root.path}/installed consumer $fixture')
      .create();
  await File('${consumer.path}/package.json')
      .writeAsString('{"private":true,"type":"module"}');
  await run('npm', [
    'install',
    '--offline',
    '--ignore-scripts',
    '--no-audit',
    '--no-fund',
    '${scalar.path}/napi-foundation-fixture-0.0.0.tgz',
  ], cwd: consumer.path);
  await File('test/integration/$fixture.mjs').copy('${consumer.path}/test.mjs');
  await File('test/typescript/$fixture.mts')
      .copy('${consumer.path}/consumer.mts');
  await run('node', ['test.mjs'], cwd: consumer.path);
  await typescript(consumer, 'consumer.mts');
}

Future<void> main() async {
  final version = await Process.run('node', ['--version']);
  stdout.writeln(
    'Node ${version.stdout.toString().trim()}; Dart ${Platform.version}',
  );
  final root = await Directory('.dart_tool').createTemp('napi conformance ');
  final scalar = Directory('${root.absolute.path}/scalars');
  await buildScalarFixture(scalar);
  await run('node', ['test.mjs'], cwd: scalar.path);
  await typescript(scalar, 'consumer.mts');
  await installedConsumer(scalar, root.absolute);
  final arguments = Directory('${root.absolute.path}/arguments');
  await buildArgumentFixture(arguments);
  await run('node', ['test.mjs'], cwd: arguments.path);
  await typescript(arguments, 'consumer.mts');
  await installedConsumer(
    arguments,
    root.absolute,
    fixture: 'arguments_package',
  );
  final structural = Directory('${root.absolute.path}/structural');
  await buildStructuralFixture(structural);
  await run('node', ['test.mjs'], cwd: structural.path);
  await typescript(structural, 'consumer.mts');
  await installedConsumer(
    structural,
    root.absolute,
    fixture: 'structural_package',
  );
  await verifyPackageAssembly(
    await Directory('${root.absolute.path}/package assembly').create(),
  );
  final classes = await Directory('${root.absolute.path}/classes').create();
  final sentinel = File('${classes.path}/business/keep.txt');
  await sentinel.parent.create();
  await sentinel.writeAsString('unrelated user file');
  await verifyClassFixture(classes);
  if (!await sentinel.exists() ||
      await sentinel.readAsString() != 'unrelated user file') {
    throw StateError(
      'Class verification must preserve an existing business directory.',
    );
  }
  final kinds = await buildExportKindFixture();
  await run('node', ['test.mjs'], cwd: kinds.path);
  await typescript(kinds, 'consumer.mts');
  stdout.writeln('Direct-Wasm conformance passed. Artifacts: ${root.path}');
}
