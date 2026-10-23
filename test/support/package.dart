import 'dart:convert';
import 'dart:io';

import 'commands.dart';

Future<void> installedConsumer(
  Directory scalar,
  Directory root, {
  String fixture = 'package',
}) async {
  // Keep direct-Wasm imports separate from generated npm package metadata.
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
