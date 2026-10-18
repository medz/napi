import 'dart:convert';
import 'dart:io';

import 'command.dart';
import 'verification_shard.dart';
import 'export_kind_fixture.dart';
import 'scalar_fixture.dart';
import 'argument_fixture.dart';
import 'structural_fixture.dart';
import 'package_assembly_fixture.dart';
import 'class_fixture.dart';
import 'future_fixture.dart';
import 'void_fixture.dart';
import 'resource_fixture.dart';
import 'opaque_fixture.dart';
import 'callback_fixture.dart';
import 'stream_fixture.dart';
import 'cancellation_fixture.dart';
import 'binary_fixture.dart';
import 'concrete_fixture.dart';
import 'shared_bytes_fixture.dart';

export 'command.dart' show run;

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
          'references.mjs',
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
  if (fixture == 'structural_package') {
    await File('test/integration/structural_contract.mjs')
        .copy('${consumer.path}/structural_contract.mjs');
  }
  await File('test/typescript/$fixture.mts')
      .copy('${consumer.path}/consumer.mts');
  await run('node', [
    if (fixture == 'structural_package') '--expose-gc',
    'test.mjs',
  ], cwd: consumer.path);
  await typescript(consumer, 'consumer.mts');
}

final consumerFixtures = <String, Future<void> Function(Directory)>{
  'scalar': (root) async {
    final scalar = Directory('${root.absolute.path}/scalars');
    await buildScalarFixture(scalar);
    await run('node', ['test.mjs'], cwd: scalar.path);
    await typescript(scalar, 'consumer.mts');
    await installedConsumer(scalar, root.absolute);
  },
  'arguments': (root) async {
    final arguments = Directory('${root.absolute.path}/arguments');
    await buildArgumentFixture(arguments);
    await run('node', ['test.mjs'], cwd: arguments.path);
    await typescript(arguments, 'consumer.mts');
    await installedConsumer(
      arguments,
      root.absolute,
      fixture: 'arguments_package',
    );
  },
  'structural': (root) async {
    final structural = Directory('${root.absolute.path}/structural');
    await buildStructuralFixture(structural);
    await run('node', ['--expose-gc', 'test.mjs'], cwd: structural.path);
    await typescript(structural, 'consumer.mts');
    await installedConsumer(
      structural,
      root.absolute,
      fixture: 'structural_package',
    );
  },
  'package-assembly': (root) async {
    await verifyPackageAssembly(
      await Directory('${root.absolute.path}/package assembly').create(),
    );
  },
  'classes': (root) async {
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
  },
  'export-kinds': (root) async {
    final kinds = await buildExportKindFixture();
    await run('node', ['test.mjs'], cwd: kinds.path);
    await typescript(kinds, 'consumer.mts');
  },
  'future': (root) async {
    await verifyFutureFixture(root.absolute);
  },
  'void': (root) async {
    await verifyVoidFixture(root.absolute);
  },
  'resource': (root) async {
    await verifyResourceFixture(root.absolute);
  },
  'opaque': (root) async {
    await verifyOpaqueFixture(root.absolute);
  },
  'callback': (root) async {
    await verifyCallbackFixture(root.absolute);
  },
  'stream': (root) async {
    await verifyStreamFixture(root.absolute);
  },
  'cancellation': (root) async {
    await verifyCancellationFixture(root.absolute);
  },
  'binary': (root) async {
    await verifyBinaryFixture(root.absolute);
  },
  'concrete': (root) async {
    await verifyConcreteFixture(root.absolute);
  },
  'shared-bytes': (root) async {
    await verifySharedBytesFixture(root.absolute);
  },
};

Future<void> main(List<String> arguments) async {
  final shard = VerificationShard.parse(arguments);
  final selected = shard.select(consumerFixtures.keys.toList());
  await reportNodeVersions();
  stdout.writeln('Dart ${Platform.version}');
  stdout.writeln('Consumer fixtures: ${selected.join(', ')}');
  final root = await Directory('.dart_tool').createTemp('napi conformance ');
  for (final name in selected) {
    final timer = Stopwatch()..start();
    await consumerFixtures[name]!(root.absolute);
    stdout.writeln('Fixture $name passed in ${timer.elapsedMilliseconds} ms.');
  }
  stdout.writeln('Direct-Wasm conformance passed. Artifacts: ${root.path}');
}
