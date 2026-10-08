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
        .writeAsString('{"napi":{"generator":"napi"},"files":["node.js"]}');
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
      ['example/math.dart', '--name', '@example/math', '--version', 'latest'],
      ['example/math.dart', '--name', '@example/math', '--version', '0.1.0-01'],
      ['example/math.dart', '--name', '@example/math', '--unknown'],
    ]) {
      final result = await build([...arguments, '--out', output]);
      expect(result.exitCode, isNot(0));
      expect(Directory(output).existsSync(), isFalse);
    }
  });
}
