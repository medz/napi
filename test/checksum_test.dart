@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final root = Directory.current;
  final fixtures = Platform.environment['NAPI_RUNTIME_FIXTURES'];
  final tsc = Platform.environment['NAPI_TSC'];
  final node =
      Platform.environment['NAPI_NODE22'] ??
      Platform.environment['NAPI_NODE'] ??
      'node';
  late Directory consumer;
  late Directory output;

  setUpAll(() async {
    if (fixtures != null) {
      consumer = Directory(p.join(p.absolute(fixtures), 'checksum'));
      output = Directory(p.join(consumer.path, 'dist'));
      expect(
        File(p.join(output.path, 'package.json')).existsSync(),
        isTrue,
        reason: 'Run dart run tool/runtime_fixtures.dart first.',
      );
      return;
    }
    consumer = await Directory.systemTemp.createTemp('napi-checksum-');
    output = Directory(p.join(consumer.path, 'dist'));
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'napi:build',
      'example/checksum/checksum.dart',
      '--name',
      '@napi/checksum',
      '--out',
      output.path,
    ], workingDirectory: root.path);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    await File(p.join(consumer.path, 'package.json')).writeAsString(
      '{"name":"napi-checksum-consumer","private":true,"type":"module"}\n',
    );
    if (tsc != null) {
      final types = await Process.run('npm', [
        'install',
        '--no-save',
        '--no-package-lock',
        '--ignore-scripts',
        '--no-audit',
        '--no-fund',
        '@types/node@26.6.4',
      ], workingDirectory: consumer.path);
      expect(types.exitCode, 0, reason: '${types.stdout}${types.stderr}');
    }
    final scope = Directory(p.join(consumer.path, 'node_modules', '@napi'));
    await scope.create(recursive: true);
    await Link(p.join(scope.path, 'checksum')).create(output.path);
    for (final file in [
      'example/checksum/main.mjs',
      'example/checksum/consumer.mts',
      'example/checksum/sample.txt',
      'test/js/checksum-node.mjs',
      'test/js/checksum-consumer.ts',
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
    'checksum application uses native Dart business logic and real I/O',
    () async {
      expect(
        (await File(p.join(output.path, 'module.wasm')).readAsBytes()).take(4),
        [0x00, 0x61, 0x73, 0x6d],
      );
      final source = await File(
        p.join(root.path, 'example/checksum/checksum.dart'),
      ).readAsString();
      expect(
        RegExp(r'^@napi$', multiLine: true).allMatches(source),
        hasLength(1),
      );
      final declarations = await File(p.join(output.path, 'index.d.ts'))
          .readAsString();
      expect(declarations, contains('export type FileInput'));
      expect(declarations, contains('export type FileChecksum'));
      expect(declarations, contains('export declare function checksum'));
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
        'checksum-node.mjs',
      ], workingDirectory: consumer.path);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      final report = jsonDecode((result.stdout as String).trim()) as Map;
      expect(report['nativeFunctions'], 1);
      expect(report['checks'] as int, greaterThanOrEqualTo(4));
      expect(report['cliChecks'] as int, greaterThanOrEqualTo(2));
      if (report['node'] == 'v22.19.0') {
        expect(report['extraCliChecks'] as int, greaterThan(0));
      } else {
        expect(report['extraCliChecks'], 0);
      }
      print('checksum: ${result.stdout}');
    },
  );

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
          '--types',
          'node',
          '--module',
          resolution == 'NodeNext' ? 'NodeNext' : 'ESNext',
          '--moduleResolution',
          resolution,
          if (arbitrary) '--allowArbitraryExtensions',
          file,
        ], workingDirectory: consumer.path);
    test(
      'TypeScript $resolution checks checksum npm aliases and signatures',
      () async {
        final result = await typecheck('checksum-consumer.ts');
        expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      },
      skip: skipTypescript,
    );
    test(
      'TypeScript $resolution checks the shipped relative checksum consumer',
      () async {
        final result = await typecheck('consumer.mts', arbitrary: true);
        expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      },
      skip: skipTypescript,
    );
  }
}
