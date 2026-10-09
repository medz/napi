@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final root = Directory.current;
  final fixtures = Platform.environment['NAPI_RUNTIME_FIXTURES'];
  final node =
      Platform.environment['NAPI_NODE22'] ??
      Platform.environment['NAPI_NODE'] ??
      'node';
  late Directory consumer;
  late Directory output;

  setUpAll(() async {
    if (fixtures != null) {
      consumer = Directory(p.join(p.absolute(fixtures), 'requests'));
      output = Directory(p.join(consumer.path, 'dist'));
      expect(
        File(p.join(output.path, 'package.json')).existsSync(),
        isTrue,
        reason: 'Run dart run tool/runtime_fixtures.dart first.',
      );
      return;
    }
    consumer = await Directory.systemTemp.createTemp('napi-requests-');
    output = Directory(p.join(consumer.path, 'dist'));
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'napi:build',
      'example/requests/summary.dart',
      '--name',
      '@napi/requests',
      '--out',
      output.path,
    ], workingDirectory: root.path);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    await File(p.join(consumer.path, 'package.json')).writeAsString(
      '{"name":"napi-requests-consumer","private":true,"type":"module"}\n',
    );
    final scope = Directory(p.join(consumer.path, 'node_modules', '@napi'));
    await scope.create(recursive: true);
    await Link(p.join(scope.path, 'requests')).create(output.path);
    for (final file in [
      'example/requests/main.mjs',
      'example/requests/consumer.mts',
      'example/requests/input.ndjson',
      'test/js/requests-node.mjs',
      'test/js/requests-consumer.ts',
    ]) {
      await File(p.join(root.path, file))
          .copy(p.join(consumer.path, p.basename(file)));
    }
  });

  tearDownAll(() async {
    if (fixtures == null && consumer.existsSync()) {
      await consumer.delete(recursive: true);
    }
  });

  test(
    'request application executes the Dart Wasm business rules and CLI',
    () async {
      final declarations = await File(p.join(output.path, 'index.d.ts'))
          .readAsString();
      expect(declarations, contains('export type Observation'));
      expect(declarations, contains('export type Summary'));
      expect(declarations, contains('summarize'));
      expect(
        await File(p.join(output.path, 'module.d.wasm.ts')).readAsString(),
        declarations,
      );
      final manifest = jsonDecode(
        await File(p.join(output.path, 'package.json')).readAsString(),
      ) as Map;
      for (final entry in ['.', './module.wasm']) {
        expect((manifest['exports'] as Map)[entry], {
          'types': './index.d.ts',
          'default': './module.wasm',
        });
      }
      expect(manifest.containsKey('dependencies'), isFalse);
      final result = await Process.run(node, [
        'requests-node.mjs',
      ], workingDirectory: consumer.path);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      final report = jsonDecode((result.stdout as String).trim()) as Map;
      expect(report['nativeFunctions'], 1);
      expect(report['checks'] as int, greaterThan(10));
      expect(report['cliChecks'] as int, greaterThan(5));
      print('requests: ${result.stdout}');
    },
  );

  final tsc = Platform.environment['NAPI_TSC'];
  final skipTypescript = tsc == null
      ? 'Set NAPI_TSC to TypeScript bin/tsc. CI requires this check.'
      : false;
  for (final resolution in ['NodeNext', 'Bundler']) {
    Future<ProcessResult> typecheck(String file, {bool arbitrary = false}) =>
        Process.run(node, [
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
    test(
      'TypeScript $resolution checks request npm aliases and signatures',
      () async {
        final result = await typecheck('requests-consumer.ts');
        expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      },
      skip: skipTypescript,
    );
    test(
      'TypeScript $resolution checks the shipped relative Wasm consumer',
      () async {
        final result = await typecheck('consumer.mts', arbitrary: true);
        expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
        final withoutOption = await typecheck('consumer.mts');
        expect(withoutOption.exitCode, isNot(0));
        expect(withoutOption.stdout, contains('TS6263'));
        expect(withoutOption.stdout, contains('module.d.wasm.ts'));
      },
      skip: skipTypescript,
    );
  }
}
