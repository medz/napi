import 'dart:io';

import 'package:test/test.dart';

import '../support/commands.dart' show nodeExecutables;
import '../support/callback_package.dart';
import '../support/process.dart';

const _scenarios = [
  'late-rejection',
  'scalars',
  'structures',
  'void',
  'validation',
  'many',
  'reentry',
  'exact-errors',
  'conversion-errors',
  'scalar-intrinsics',
  'stored-errors',
  'retained-gc',
  'scheduled',
  'resources',
  'identity',
  'async-values',
  'async-validation',
  'async-errors',
  'async-retention',
  'async-resources',
  'stream-values',
  'stream-errors',
  'stream-resources',
  'stream-retention',
  'js-handles',
  'async-handles',
  'foreign-owner',
  'pending-natural-exit',
  'queued-teardown',
  'external',
  'worker-only',
  'workers-with-main',
];

void callbackTests({required bool native}) {
  final backend = native ? 'native' : 'wasm';
  final nodes = nodeExecutables();
  // TypeScript is independent of the runtime matrix and runs on one host.
  final typescriptNode = Platform.environment['NAPI_TEST_NODE'] ?? 'node';
  final tsc = File(
    Platform.environment['NAPI_TSC'] ??
        '${Directory.current.path}/.dart_tool/js/node_modules/typescript/bin/tsc',
  );
  Directory? root;
  late Directory consumer;

  group('callback $backend', () {
    setUpAll(() async {
      if (!tsc.existsSync()) {
        throw StateError(
          'Install TypeScript 7.0.2 under .dart_tool/js, or set NAPI_TSC.',
        );
      }
      for (final node in {...nodes, typescriptNode}) {
        final result = await runProcess(node, [
          '--version',
        ], timeout: const Duration(seconds: 10));
        expect(
          result.stdout.toString().trim(),
          matches(r'^v\d+\.\d+\.\d+(?:[-+][\w.-]+)?$'),
        );
        print('Node ${result.stdout.toString().trim()}: $node');
      }
      root = await Directory('.dart_tool').createTemp('napi callback suite ');
      consumer = await buildOwnedCallbackPackage(
        root!.absolute,
        native: native,
      );
    });

    tearDownAll(() async {
      final directory = root;
      if (directory == null) return;
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    for (final (index, node) in nodes.indexed) {
      group('Node ${index + 1}', () {
        for (final scenario in _scenarios) {
          test(scenario, () async {
            final result = await runProcess(
              node,
              [
                '--expose-gc',
                '--unhandled-rejections=throw',
                'test.mjs',
                scenario,
              ],
              workingDirectory: consumer.path,
              timeout: const Duration(seconds: 30),
              checkExitCode: scenario != 'late-rejection',
            );
            if (scenario == 'late-rejection') {
              // A timeout, launch failure, or signal must not satisfy this case.
              expect(result.exitCode, greaterThan(0));
              expect(result.stderr, contains('callback-late-rejection'));
            }
          }, timeout: const Timeout(Duration(seconds: 45)));
        }
      });
    }

    group('TypeScript', () {
      for (final mode in ['NodeNext', 'Bundler']) {
        for (final exact in ['true', 'false']) {
          for (final strictFunctions in ['true', 'false']) {
            test('$mode exact=$exact strictFunctions=$strictFunctions', () async {
              // TS 7 can spawn its native compiler; wait before deleting files.
              final arguments = [
                tsc.absolute.path,
                '--ignoreConfig',
                '--strict',
                '--exactOptionalPropertyTypes',
                exact,
                '--strictFunctionTypes',
                strictFunctions,
                '--noEmit',
                '--target',
                'ES2022',
                '--module',
                mode == 'NodeNext' ? 'NodeNext' : 'ESNext',
                '--moduleResolution',
                mode,
                '--allowArbitraryExtensions',
                'consumer.mts',
              ];
              await runProcess(
                typescriptNode,
                arguments,
                workingDirectory: consumer.path,
                timeout: const Duration(seconds: 30),
              );
            }, timeout: const Timeout(Duration(seconds: 45)));
          }
        }
      }
    });
  }, timeout: const Timeout(Duration(minutes: 4)));
}
