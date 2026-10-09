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
      consumer = Directory(p.join(p.absolute(fixtures), 'records'));
      output = Directory(p.join(consumer.path, 'dist'));
      expect(
        File(p.join(output.path, 'package.json')).existsSync(),
        isTrue,
        reason: 'Run dart run tool/runtime_fixtures.dart first.',
      );
      return;
    }
    consumer = await Directory.systemTemp.createTemp('napi-records-');
    output = Directory(p.join(consumer.path, 'dist'));
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'napi:build',
      'test/fixtures/records.dart',
      '--name',
      '@napi/records',
      '--out',
      output.path,
      '--version',
      '0.5.0',
    ], workingDirectory: root.path);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    await File(p.join(consumer.path, 'package.json')).writeAsString(
      '{"name":"napi-records-consumer","private":true,"type":"module"}\n',
    );
    final scope = Directory(p.join(consumer.path, 'node_modules', '@napi'));
    await scope.create(recursive: true);
    await Link(p.join(scope.path, 'records')).create(output.path);
    for (final file in [
      'records-node.mjs',
      'records-consumer.ts',
      'records-relative.ts',
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

  test(
    'named records preserve native exports, validation, and snapshots',
    () async {
      final result = await Process.run(node, [
        '--expose-gc',
        'records-node.mjs',
      ], workingDirectory: consumer.path);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      final report = jsonDecode((result.stdout as String).trim()) as Map;
      expect(report['checks'] as int, greaterThan(1000));
      expect(report['nativeFunctions'], 33);
      expect(report['retained'], isA<Map>());
      print('records: ${result.stdout}');
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
      'TypeScript $resolution checks record npm root and subpath signatures',
      () async {
        final result = await typecheck('records-consumer.ts');
        expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      },
      skip: skipTypescript,
    );
    test(
      'TypeScript $resolution checks relative Wasm record declarations',
      () async {
        final result = await typecheck('records-relative.ts', arbitrary: true);
        expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
        final withoutOption = await typecheck('records-relative.ts');
        expect(withoutOption.exitCode, isNot(0));
        expect(withoutOption.stdout, contains('TS6263'));
        expect(withoutOption.stdout, contains('module.d.wasm.ts'));
      },
      skip: skipTypescript,
    );
  }
}
