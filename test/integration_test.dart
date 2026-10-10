@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final root = Directory.current;
  final fixtures = Platform.environment['NAPI_RUNTIME_FIXTURES'];
  late Directory consumer;
  late Directory output;

  setUpAll(() async {
    if (fixtures != null) {
      consumer = Directory(p.join(p.absolute(fixtures), 'integration'));
      output = Directory(p.join(consumer.path, 'dist'));
      expect(
        File(p.join(output.path, 'package.json')).existsSync(),
        isTrue,
        reason: 'Run dart run tool/runtime_fixtures.dart first.',
      );
      return;
    }
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
    for (final file in [
      'node.mjs',
      'assertions.mjs',
      'consumer.ts',
      'relative.ts',
    ]) {
      await File(p.join(root.path, 'test', 'js', file))
          .copy(p.join(consumer.path, file));
    }
  });

  tearDownAll(() async {
    if (fixtures == null && consumer.existsSync()) {
      await consumer.delete(recursive: true);
    }
  });

  test('build emits a native Wasm package with companion declarations', () {
    final manifest = jsonDecode(
      File(p.join(output.path, 'package.json')).readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(manifest['name'], '@napi/integration');
    expect(manifest['version'], '0.1.0');
    expect(manifest['type'], 'module');
    expect(manifest['dependencies'], isNull);
    expect((manifest['engines'] as Map)['node'], '^22.19.0 || >=24.5.0');
    final exports = manifest['exports'] as Map;
    for (final entry in ['.', './module.wasm']) {
      expect(exports[entry], {
        'types': './index.d.ts',
        'default': './module.wasm',
      });
    }
    expect(
      manifest['files'],
      unorderedEquals([
        'module.wasm',
        'module.imports.mjs',
        'index.d.ts',
        'module.d.wasm.ts',
      ]),
    );
    final wasm = File(p.join(output.path, 'module.wasm')).readAsBytesSync();
    expect(wasm.take(8), [0, 97, 115, 109, 1, 0, 0, 0]);
    for (final asset in (manifest['files'] as List).cast<String>()) {
      expect(
        File(p.join(output.path, asset)).existsSync(),
        isTrue,
        reason: asset,
      );
    }
  });

  test(
    'Node imports raw Wasm functions through package and relative paths',
    () async {
      final result = await Process.run('node', [
        '--expose-gc',
        'node.mjs',
      ], workingDirectory: consumer.path);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      final report = jsonDecode((result.stdout as String).trim()) as Map;
      expect(report['checks'] as int, greaterThan(10000));
      expect(report['nativeFunctions'], 29);
      expect(report['retained'], isA<Map>());
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  final tsc = Platform.environment['NAPI_TSC'];
  final skipTypescript = tsc == null
      ? 'Set NAPI_TSC to TypeScript bin/tsc. CI requires this check.'
      : false;
  for (final resolution in ['NodeNext', 'Bundler']) {
    Future<ProcessResult> typecheck(String file, {bool arbitrary = false}) {
      return Process.run('node', [
        tsc!,
        '--strict',
        '--noEmit',
        '--target',
        'ES2022',
        '--module',
        resolution == 'NodeNext' ? 'NodeNext' : 'ESNext',
        '--moduleResolution',
        resolution,
        if (arbitrary) '--allowArbitraryExtensions',
        file,
      ], workingDirectory: consumer.path);
    }

    test(
      'TypeScript $resolution checks package exports without extension options',
      () async {
        final result = await typecheck('consumer.ts');
        expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      },
      skip: skipTypescript,
    );

    test(
      'TypeScript $resolution resolves the relative Wasm companion',
      () async {
        final result = await typecheck('relative.ts', arbitrary: true);
        expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
        final withoutOption = await typecheck('relative.ts');
        expect(withoutOption.exitCode, isNot(0));
        expect(withoutOption.stdout, contains('TS6263'));
        expect(withoutOption.stdout, contains('module.d.wasm.ts'));
      },
      skip: skipTypescript,
    );
  }
}
