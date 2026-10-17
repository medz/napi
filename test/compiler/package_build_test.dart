import 'dart:convert';
import 'dart:io';

import 'package:napi/build.dart';
import 'package:napi/src/build/metadata.dart';
import 'package:test/test.dart';

// Expected supported Node inventory; checked against the actual runtime below.
const _bareBuiltins = [
  'assert',
  'async_hooks',
  'buffer',
  'child_process',
  'cluster',
  'console',
  'constants',
  'crypto',
  'dgram',
  'diagnostics_channel',
  'dns',
  'domain',
  'events',
  'fs',
  'http',
  'http2',
  'https',
  'inspector',
  'module',
  'net',
  'os',
  'path',
  'perf_hooks',
  'process',
  'punycode',
  'querystring',
  'readline',
  'repl',
  'stream',
  'string_decoder',
  'sys',
  'timers',
  'tls',
  'trace_events',
  'tty',
  'url',
  'util',
  'v8',
  'vm',
  'wasi',
  'worker_threads',
  'zlib',
];

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory(await Directory.systemTemp.resolveSymbolicLinks())
        .createTemp('napi package preflight ');
  });
  tearDown(() => root.delete(recursive: true));

  Future<Directory> build(String name, BuildTarget target, Directory output) =>
      buildPackage(
        library: File('${root.path}/missing.dart').uri,
        output: output,
        metadata: {'name': name, 'version': '1.0.0'},
        target: target,
      );

  test(
    'rejection coverage agrees with the actual Node bare built-ins',
    () async {
      final result = await Process.run(
        Platform.environment['NAPI_TEST_NODE'] ?? 'node',
        [
          '--input-type=module',
          '-e',
          '''
import {builtinModules, isBuiltin} from 'node:module';
const names = builtinModules.filter(name =>
  /^[a-z0-9][a-z0-9._-]*\$/.test(name) && isBuiltin(name));
console.log(JSON.stringify(names.sort()));
''',
        ],
      );
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(jsonDecode(result.stdout as String), _bareBuiltins);
      for (final name in _bareBuiltins) {
        expect(
          () => packageMetadata({'name': name, 'version': '1.0.0'}),
          throwsA(
            isA<ArgumentError>().having(
              (error) => error.message,
              'scoped alternative',
              contains('@scope/$name'),
            ),
          ),
        );
        expect(
          packageMetadata({'name': '@scope/$name', 'version': '1.0.0'})['name'],
          '@scope/$name',
        );
      }
    },
  );

  for (final target in BuildTarget.values) {
    test('$target rejects all collisions before analysis or staging', () async {
      for (final name in _bareBuiltins) {
        await expectLater(
          build(name, target, Directory('${root.path}/absent/package')),
          throwsA(
            isA<ArgumentError>().having(
              (error) => error.message,
              'offending name',
              contains('"$name" shadows a Node built-in'),
            ),
          ),
        );
        expect(await root.list().length, 0);
      }
    });

    test('$target rejects collisions before reading a built module', () async {
      final module = BuiltModule(
        Directory('${root.path}/missing module'),
        '3.13.5',
        target: target,
      );
      for (final name in _bareBuiltins) {
        final assemble = target == BuildTarget.wasm
            ? assembleWasmPackage
            : assembleNativePackage;
        await expectLater(
          assemble(
            module: module,
            output: Directory('${root.path}/absent/package'),
            metadata: {'name': name, 'version': '1.0.0'},
          ),
          throwsA(
            isA<ArgumentError>().having(
              (error) => error.message,
              'offending name',
              contains('"$name" shadows a Node built-in'),
            ),
          ),
        );
        expect(await root.list().length, 0);
      }
    });
  }

  test('native platform metadata fails before source analysis', () async {
    for (final field in ['os', 'cpu']) {
      await expectLater(
        buildPackage(
          library: File('${root.path}/missing.dart').uri,
          output: Directory('${root.path}/absent/package'),
          metadata: {
            'name': 'ordinary-package',
            'version': '1.0.0',
            field: ['unsupported'],
          },
          target: BuildTarget.native,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'platform conflict',
            contains('Native package metadata $field must match'),
          ),
        ),
      );
      expect(await root.list().length, 0);
    }
  });

  for (final kind in ['file', 'directory', 'symlink']) {
    test('preflight preserves an existing $kind output', () async {
      final output = Directory('${root.path}/output');
      if (kind == 'file') {
        await File(output.path).writeAsString('keep');
      } else if (kind == 'directory') {
        await output.create();
        await File('${output.path}/keep').writeAsString('keep');
      } else {
        await Link(output.path).create('${root.path}/absent');
      }
      for (final target in BuildTarget.values) {
        for (final name in [..._bareBuiltins, 'ordinary-package']) {
          await expectLater(build(name, target, output), throwsArgumentError);
        }
      }
      if (kind == 'symlink') {
        expect(await Link(output.path).target(), '${root.path}/absent');
      } else {
        expect(
          await File(kind == 'file' ? output.path : '${output.path}/keep')
              .readAsString(),
          'keep',
        );
      }
      expect(await root.list().length, 1);
    });
  }

  test('failed source analysis removes intermediate build files', () async {
    await expectLater(
      build(
        'ordinary-package',
        BuildTarget.wasm,
        Directory('${root.path}/out'),
      ),
      throwsA(isA<Exception>()),
    );
    expect(await root.list().length, 0);
  });

  test('validation and assembly need no Node executable', () async {
    final script = File('${root.path}/without_node.dart');
    await script.writeAsString(r'''
import 'dart:io';
import 'package:napi/build.dart';
Future<void> main() async {
  for (final target in BuildTarget.values) {
    try {
      await buildPackage(library: File('missing.dart').absolute.uri,
        output: Directory('never created'), target: target,
        metadata: {'name': 'path', 'version': '1.0.0'});
      throw StateError('Accepted a bare built-in');
    } on ArgumentError catch (error) {
      if (!error.toString().contains('@scope/path')) rethrow;
    }
  }
  final source = await Directory('module').create();
  for (final name in ['module.wasm', 'module.d.wasm.ts', 'host.mjs',
      'boundary.mjs', 'DART_LICENSE']) {
    await File('${source.path}/$name').writeAsString(name);
  }
  for (final name in ['ordinary-package', '@scope/path', '@scope/fs',
      'test', 'sqlite', 'sea', 'ffi']) {
    final output = await assembleWasmPackage(
      module: BuiltModule(source, '3.13.5'), output: Directory('package'),
      metadata: {'name': name, 'version': '1.0.0'});
    await output.delete(recursive: true);
  }
}
''');
    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        '--packages=${File('.dart_tool/package_config.json').absolute.path}',
        script.path,
      ],
      workingDirectory: root.path,
      environment: {'PATH': ''},
    );
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    expect(await Directory('${root.path}/never created').exists(), isFalse);
  });
}
