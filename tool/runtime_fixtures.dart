import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

Future<void> main(List<String> arguments) async {
  if (arguments.length > 1) {
    throw ArgumentError('Usage: dart run tool/runtime_fixtures.dart [output]');
  }
  final root = Directory.current.path;
  final fixtures = Directory(
    p.absolute(
      arguments.isEmpty ? '.dart_tool/runtime-fixtures' : arguments[0],
    ),
  );
  final type = FileSystemEntity.typeSync(fixtures.path, followLinks: false);
  if (type != FileSystemEntityType.notFound &&
      (type != FileSystemEntityType.directory ||
          fixtures.listSync().isNotEmpty)) {
    throw ArgumentError('Fixture output must be a new or empty directory.');
  }
  await fixtures.create(recursive: true);

  Future<ProcessResult> run(
    String executable,
    List<String> args,
    String workingDirectory,
  ) async {
    final result = await Process.run(
      executable,
      args,
      workingDirectory: workingDirectory,
    );
    if (result.exitCode != 0) {
      throw ProcessException(
        executable,
        args,
        '${result.stdout}${result.stderr}',
        result.exitCode,
      );
    }
    return result;
  }

  for (final fixture in [
    (
      name: 'integration',
      source: 'api',
      version: '0.1.0',
      files: ['node.mjs', 'assertions.mjs', 'consumer.ts', 'relative.ts'],
    ),
    (
      name: 'async',
      source: 'async',
      version: '0.2.0',
      files: ['async-node.mjs', 'async-consumer.ts', 'async-relative.ts'],
    ),
    (
      name: 'collections',
      source: 'collections',
      version: '0.3.0',
      files: [
        'collections-node.mjs',
        'collections-consumer.ts',
        'collections-relative.ts',
      ],
    ),
  ]) {
    final consumer = Directory(p.join(fixtures.path, fixture.name));
    final output = Directory(p.join(consumer.path, 'dist'));
    await consumer.create();
    await run(Platform.resolvedExecutable, [
      'run',
      'napi:build',
      'test/fixtures/${fixture.source}.dart',
      '--name',
      '@napi/${fixture.name}',
      '--out',
      output.path,
      '--version',
      fixture.version,
    ], root);
    await File(p.join(consumer.path, 'package.json')).writeAsString(
      '{"name":"napi-${fixture.name}-consumer","private":true,"type":"module"}\n',
    );
    final packed = await run('npm', [
      'pack',
      '--json',
      '--pack-destination',
      consumer.path,
    ], output.path);
    final archive = (jsonDecode(packed.stdout as String) as List).single as Map;
    await run('npm', [
      'install',
      '--no-save',
      '--no-package-lock',
      '--ignore-scripts',
      '--no-audit',
      '--no-fund',
      p.join(consumer.path, archive['filename'] as String),
    ], consumer.path);
    final installed = p.join(
      consumer.path,
      'node_modules',
      '@napi',
      fixture.name,
    );
    if (!File(p.join(installed, 'module.wasm')).existsSync()) {
      throw StateError('npm did not install @napi/${fixture.name}.');
    }
    // This directory was created above; the output root was empty on entry.
    await output.delete(recursive: true);
    await Link(output.path).create(p.relative(installed, from: consumer.path));
    for (final filename in fixture.files) {
      await File(p.join(root, 'test', 'js', filename))
          .copy(p.join(consumer.path, filename));
    }
    stdout.writeln('${fixture.name}: built, packed and installed');
  }
  await File(p.join(fixtures.path, 'metadata.json'))
      .writeAsString('${jsonEncode({'dart': Platform.version})}\n');
}
