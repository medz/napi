@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final root = Directory.current;
  late Directory consumer;
  late Directory output;

  setUpAll(() async {
    consumer = await Directory.systemTemp.createTemp('napi-integration-');
    output = Directory(p.join(consumer.path, 'dist'));
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'napi:build',
      'test/fixtures/api.dart',
      '--name',
      '@napi/integration',
      '--out',
      output.path,
      '--version',
      '0.1.0',
    ], workingDirectory: root.path);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');

    await File(p.join(consumer.path, 'package.json')).writeAsString(
      '{"name":"napi-test-consumer","private":true,"type":"module"}\n',
    );
    final scope = Directory(p.join(consumer.path, 'node_modules', '@napi'));
    await scope.create(recursive: true);
    await Link(p.join(scope.path, 'integration')).create(output.path);
    for (final file in ['node.mjs', 'assertions.mjs', 'consumer.ts']) {
      await File(p.join(root.path, 'test', 'js', file))
          .copy(p.join(consumer.path, file));
    }
  });

  tearDownAll(() async {
    if (consumer.existsSync()) await consumer.delete(recursive: true);
  });

  test(
    'build emits a standalone package with real Wasm and no npm dependencies',
    () {
      final manifest = jsonDecode(
        File(p.join(output.path, 'package.json')).readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(manifest['name'], '@napi/integration');
      expect(manifest['version'], '0.1.0');
      expect(manifest['type'], 'module');
      expect(manifest['dependencies'], isNull);
      final exports = (manifest['exports'] as Map)['.'] as Map;
      expect(exports['types'], './index.d.ts');
      expect(exports['node'], './node.js');
      expect(exports['browser'], './browser.js');
      final wasm = File(p.join(output.path, 'module.wasm')).readAsBytesSync();
      expect(wasm.take(8), [0, 97, 115, 109, 1, 0, 0, 0]);
      for (final asset in (manifest['files'] as List).cast<String>()) {
        expect(
          File(p.join(output.path, asset)).existsSync(),
          isTrue,
          reason: asset,
        );
      }
    },
  );

  test('a fresh Node consumer runs the generated package and releases temporary buffers', () async {
    final result = await Process.run('node', [
      '--expose-gc',
      'node.mjs',
    ], workingDirectory: consumer.path);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    final report = jsonDecode((result.stdout as String).trim()) as Map;
    expect(report['checks'] as int, greaterThan(10000));
    expect(report['retained'], isA<Map>());
  }, timeout: const Timeout(Duration(minutes: 2)));

  final tsc = Platform.environment['NAPI_TSC'];
  test(
    'a strict TypeScript consumer checks all generated signatures',
    () async {
      final result = await Process.run('node', [
        tsc!,
        '--strict',
        '--noEmit',
        '--target',
        'ES2022',
        '--module',
        'NodeNext',
        '--moduleResolution',
        'NodeNext',
        'consumer.ts',
      ], workingDirectory: consumer.path);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    },
    skip: tsc == null
        ? 'Set NAPI_TSC to TypeScript bin/tsc. CI requires this check.'
        : false,
  );
}
