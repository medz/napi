import 'dart:io';

import 'package:napi/src/build/native_bundle.dart';
import 'package:test/test.dart';

import '../../tool/command.dart' show nodeExecutables;
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
  'foreign-owner',
  'pending-natural-exit',
  'queued-teardown',
  'external',
  'worker-only',
  'workers-with-main',
];

/// Register one backend's installed-package checks without a custom runner.
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
  var buildSettled = false;
  var pendingTypechecks = 0;

  group('callback $backend', () {
    setUpAll(() async {
      Directory? bundle;
      if (native) {
        final configured = Platform.environment['NAPI_TEST_NATIVE_RUNTIME'];
        if (configured == null || configured.isEmpty) {
          throw StateError(
            'callback-native requires NAPI_TEST_NATIVE_RUNTIME; '
            'provide a qualified bundle, no download or native skip is performed.',
          );
        }
        bundle = Directory(configured).absolute;
        await NativeRuntimeBundle.read(bundle);
      }
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
      print('TypeScript host: $typescriptNode');
      root = await Directory('.dart_tool').createTemp('napi callback suite ');
      print('Callback $backend artifacts: ${root!.absolute.path}');
      try {
        consumer = await buildCallbackPackage(
          root!.absolute,
          nativeRuntime: bundle,
        );
      } finally {
        buildSettled = true;
      }
      print(
        'Callback $backend: source/external built once, packed and installed offline.',
      );
    });

    tearDownAll(() async {
      final directory = root;
      if (directory == null) return;
      if (!buildSettled || pendingTypechecks != 0) {
        // A package:test timeout does not cancel a compiler/npm/TS tree.
        print(
          'Build/typecheck has not settled; preserving ${directory.path}. '
          'Subprocess-tree cancellation remains unresolved in #200.',
        );
        return;
      }
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
              // TS 7 may execFileSync its native compiler (notably on Windows).
              // Keep the existing tree-spawning path until #200 owns such trees.
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
              pendingTypechecks++;
              try {
                final result = await Process.run(
                  typescriptNode,
                  arguments,
                  workingDirectory: consumer.path,
                );
                expect(
                  result.exitCode,
                  0,
                  reason:
                      '$typescriptNode ${arguments.join(' ')}\n'
                      'Working directory: ${consumer.path}\n'
                      'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
                );
              } finally {
                pendingTypechecks--;
              }
            }, timeout: const Timeout(Duration(seconds: 45)));
          }
        }
      }
    });
  }, timeout: const Timeout(Duration(minutes: 3)));
}
