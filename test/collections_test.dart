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
      consumer = Directory(p.join(p.absolute(fixtures), 'collections'));
      output = Directory(p.join(consumer.path, 'dist'));
      expect(
        File(p.join(output.path, 'package.json')).existsSync(),
        isTrue,
        reason: 'Run dart run tool/runtime_fixtures.dart first.',
      );
      return;
    }
    consumer = await Directory.systemTemp.createTemp('napi-collections-');
    output = Directory(p.join(consumer.path, 'dist'));
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'napi:build',
      'test/fixtures/collections.dart',
      '--name',
      '@napi/collections',
      '--out',
      output.path,
      '--version',
      '0.3.0',
    ], workingDirectory: root.path);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    await File(p.join(consumer.path, 'package.json')).writeAsString(
      '{"name":"napi-collections-consumer","private":true,"type":"module"}\n',
    );
    final scope = Directory(p.join(consumer.path, 'node_modules', '@napi'));
    await scope.create(recursive: true);
    await Link(p.join(scope.path, 'collections')).create(output.path);
    for (final file in [
      'collections-node.mjs',
      'collections-consumer.ts',
      'collections-relative.ts',
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
    'typed collections preserve native exports, validation, and ownership',
    () async {
      final result = await Process.run(node, [
        '--expose-gc',
        'collections-node.mjs',
      ], workingDirectory: consumer.path);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      final report = jsonDecode((result.stdout as String).trim()) as Map;
      expect(report['checks'] as int, greaterThan(1000));
      expect(report['nativeFunctions'], 102);
      expect(report['retained'], isA<Map>());
      print('collections: ${result.stdout}');
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
      'TypeScript $resolution checks collection npm root and subpath signatures',
      () async {
        final result = await typecheck('collections-consumer.ts');
        expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      },
      skip: skipTypescript,
    );
    test(
      'TypeScript $resolution checks relative Wasm collection declarations',
      () async {
        final result = await typecheck(
          'collections-relative.ts',
          arbitrary: true,
        );
        expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
        final withoutOption = await typecheck('collections-relative.ts');
        expect(withoutOption.exitCode, isNot(0));
        expect(withoutOption.stdout, contains('TS6263'));
        expect(withoutOption.stdout, contains('module.d.wasm.ts'));
      },
      skip: skipTypescript,
    );
  }
}
