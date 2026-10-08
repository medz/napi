import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final root = Directory.current.path;
  late Directory work;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('napi-output-safety-');
  });
  tearDown(() => work.delete(recursive: true));

  Future<ProcessResult> build(List<String> arguments) => Process.run(
    Platform.resolvedExecutable,
    ['run', 'napi:build', ...arguments],
    workingDirectory: root,
  );

  test('refuses unrelated output without changing its contents', () async {
    final sentinel = File(p.join(work.path, 'important.txt'));
    await sentinel.writeAsString('preserve me');
    final result = await build([
      'example/math.dart',
      '--name',
      '@example/math',
      '--out',
      work.path,
    ]);
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('not an empty or generated napi directory'));
    expect(await sentinel.readAsString(), 'preserve me');
    expect(work.listSync().length, 1);
  });

  test('refuses a symbolic-link output directory', () async {
    final target = Directory(p.join(work.path, 'target'));
    await target.create();
    final link = Link(p.join(work.path, 'output'));
    await link.create(target.path);
    final result = await build([
      'example/math.dart',
      '--name',
      '@example/math',
      '--out',
      link.path,
    ]);
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('must not be a symbolic link'));
    expect(target.listSync(), isEmpty);
  });

  test('refuses an output containing the input library', () async {
    final original = await File(p.join(root, 'example', 'math.dart'))
        .readAsString();
    final result = await build([
      'example/math.dart',
      '--name',
      '@example/math',
      '--out',
      root,
    ]);
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('contains the input source'));
    expect(
      await File(p.join(root, 'example', 'math.dart')).readAsString(),
      original,
    );
  });

  test('does not trust a generated manifest with unrelated files', () async {
    await File(p.join(work.path, 'package.json'))
        .writeAsString('{"napi":{"generator":"napi"},"files":["index.d.ts"]}');
    final sentinel = File(p.join(work.path, 'user-code.js'));
    await sentinel.writeAsString('const keep = true;');
    final result = await build([
      'example/math.dart',
      '--name',
      '@example/math',
      '--out',
      work.path,
    ]);
    expect(result.exitCode, isNot(0));
    expect(await sentinel.readAsString(), 'const keep = true;');
  });

  test('invalid package metadata and options never create output', () async {
    final output = p.join(work.path, 'dist');
    for (final arguments in [
      ['example/math.dart', '--name', 'Invalid Name'],
      ['example/math.dart', '--name', '_invalid'],
      ['example/math.dart', '--name', '.invalid'],
      ['example/math.dart', '--name', 'favicon.ico'],
      ['example/math.dart', '--name', '@example/math', '--version', 'latest'],
      ['example/math.dart', '--name', '@example/math', '--version', '0.1.0-01'],
      ['example/math.dart', '--name', '@example/math', '--unknown'],
    ]) {
      final result = await build([...arguments, '--out', output]);
      expect(result.exitCode, isNot(0));
      expect(Directory(output).existsSync(), isFalse);
    }
  });

  test(
    'resolves output ancestors before checking source containment',
    () async {
      final alias = Link(p.join(work.path, 'repository'));
      await alias.create(root);
      final result = await build([
        'example/math.dart',
        '--name',
        '@example/math',
        '--out',
        p.join(alias.path, 'example'),
      ]);
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('contains the input source'));
    },
  );

  test('builds a workspace member using the shared package configuration', () async {
    final member = Directory(p.join(work.path, 'packages', 'api'));
    await Directory(p.join(member.path, 'lib')).create(recursive: true);
    await File(p.join(work.path, 'pubspec.yaml')).writeAsString('''
name: napi_workspace_fixture
environment:
  sdk: ^3.13.5
workspace:
  - packages/api
''');
    await File(p.join(member.path, 'pubspec.yaml')).writeAsString('''
name: napi_workspace_api
resolution: workspace
environment:
  sdk: ^3.13.5
dependencies:
  napi:
    path: ${jsonEncode(root)}
''');
    final source = File(p.join(member.path, 'lib', 'api.dart'));
    await source.writeAsString(
      "import 'package:napi/napi.dart';\n@napi\nint answer() => 42;\n",
    );
    final resolved = await Process.run(Platform.resolvedExecutable, [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: work.path);
    expect(
      resolved.exitCode,
      0,
      reason: '${resolved.stdout}${resolved.stderr}',
    );
    expect(
      File(p.join(member.path, '.dart_tool', 'package_config.json'))
          .existsSync(),
      isFalse,
    );
    final output = p.join(work.path, 'dist');
    final result = await build([
      source.path,
      '--name',
      '@example/workspace',
      '--out',
      output,
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    final imported = await Process.run('node', [
      '--input-type=module',
      '-e',
      'import { answer } from ${jsonEncode(File(p.join(output, 'module.wasm')).uri.toString())}; console.log(answer());',
    ]);
    expect(
      imported.exitCode,
      0,
      reason: '${imported.stdout}${imported.stderr}',
    );
    expect((imported.stdout as String).trim(), '42');
  });

  test(
    'standalone nested packages require their own package configuration',
    () async {
      final member = Directory(p.join(work.path, 'packages', 'api'));
      await Directory(p.join(member.path, 'lib')).create(recursive: true);
      await File(p.join(work.path, 'pubspec.yaml')).writeAsString('''
name: unrelated_parent
environment:
  sdk: ^3.13.5
''');
      await Directory(p.join(work.path, '.dart_tool')).create();
      await File(p.join(work.path, '.dart_tool', 'package_config.json'))
          .writeAsString(
            jsonEncode({
              'configVersion': 2,
              'packages': [
                {'name': 'nested_api', 'rootUri': '../packages/api'},
              ],
            }),
          );
      await File(p.join(member.path, 'pubspec.yaml')).writeAsString('''
name: nested_api
environment:
  sdk: ^3.13.5
''');
      final source = File(p.join(member.path, 'lib', 'api.dart'));
      await source.writeAsString('int answer() => 42;');
      final output = p.join(work.path, 'dist');
      final result = await build([
        source.path,
        '--name',
        '@example/nested',
        '--out',
        output,
      ]);
      expect(result.exitCode, isNot(0));
      expect(
        result.stderr,
        contains('Run dart pub get in the source package first'),
      );
      expect(Directory(output).existsSync(), isFalse);
    },
  );

  test(
    'a staging I/O failure preserves the previous generated package',
    () async {
      final parent = Directory(p.join(work.path, 'protected'));
      final output = Directory(p.join(parent.path, 'dist'));
      await output.create(recursive: true);
      final manifest = File(p.join(output.path, 'package.json'));
      final previous = File(p.join(output.path, 'index.d.ts'));
      await manifest.writeAsString(
        '{"napi":{"generator":"napi"},"files":["index.d.ts"]}',
      );
      await previous.writeAsString('export const previous = 42;');
      final chmod = await Process.run('chmod', ['u-w', parent.path]);
      try {
        expect(chmod.exitCode, 0, reason: '${chmod.stdout}${chmod.stderr}');
        final probe = File(p.join(parent.path, 'permission-probe'));
        try {
          await probe.writeAsString('probe');
          await probe.delete();
          markTestSkipped('The process can write to a read-only directory.');
          return;
        } on FileSystemException {
          // Confirmed that staging cannot create files in this directory.
        }
        final result = await build([
          'example/math.dart',
          '--name',
          '@example/math',
          '--out',
          output.path,
        ]);
        expect(result.exitCode, isNot(0));
        expect(await previous.readAsString(), 'export const previous = 42;');
        expect(output.listSync().length, 2);
      } finally {
        await Process.run('chmod', ['u+w', parent.path]);
      }
    },
    skip: Platform.isWindows ? 'Requires POSIX directory permissions.' : false,
  );

  test(
    'replaces a generated package completely on a successful rebuild',
    () async {
      final output = Directory(p.join(work.path, 'dist'));
      await output.create();
      await File(
        p.join(output.path, 'package.json'),
      ).writeAsString('{"napi":{"generator":"napi"},"files":["index.d.ts"]}');
      await File(p.join(output.path, 'index.d.ts'))
          .writeAsString('export const previous = 42;');
      final result = await build([
        'example/math.dart',
        '--name',
        '@_example/_rebuilt',
        '--out',
        output.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      final manifest = jsonDecode(
        await File(p.join(output.path, 'package.json')).readAsString(),
      ) as Map;
      expect(manifest['name'], '@_example/_rebuilt');
      expect(
        await File(p.join(output.path, 'index.d.ts')).readAsString(),
        isNot(contains('previous')),
      );
      expect(File(p.join(output.path, 'module.wasm')).existsSync(), isTrue);
      expect(work.listSync().map((entry) => p.basename(entry.path)), ['dist']);
    },
  );
}
