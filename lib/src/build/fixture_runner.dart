import 'dart:convert';
import 'dart:io';

/// Validates a locally packed fixture in a clean ESM consumer.
Future<void> runFixtureChecks({
  required String projectRoot,
  required Directory package,
  String node = 'node',
  String bun = 'bun',
  String npm = 'npm',
  String tsc = 'tsc',
}) async {
  final root = Directory(projectRoot).absolute.path;
  final marker = File('${package.path}/.napi-fixture-owned');
  if (!await marker.exists() ||
      await marker.readAsString() != 'napi fixture v1\n') {
    throw ArgumentError(
      'Only freshly generated napi fixture packages may be packed.',
    );
  }
  Future<String> run(
    String executable,
    List<String> arguments,
    String cwd,
  ) async {
    final result = await Process.run(
      executable,
      arguments,
      workingDirectory: cwd,
    );
    if (result.exitCode != 0) {
      throw ProcessException(
        executable,
        arguments,
        '${result.stdout}\n${result.stderr}',
        result.exitCode,
      );
    }
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    return result.stdout as String;
  }

  final packed = await run(npm, [
    'pack',
    '--json',
    '--ignore-scripts',
  ], package.path);
  final packResult = jsonDecode(packed) as List<dynamic>;
  final archive =
      (packResult.single as Map<String, dynamic>)['filename'] as String;
  final consumer = await Directory('$root/.dart_tool/napi-fixtures')
      .createTemp('consumer-');
  await File('${consumer.path}/.napi-fixture-owned')
      .writeAsString('napi fixture consumer v1\n');
  await File('${consumer.path}/package.json')
      .writeAsString('{"private":true,"type":"module"}');
  await run(npm, [
    'install',
    '--ignore-scripts',
    '--no-audit',
    '--no-fund',
    '${package.path}/$archive',
  ], consumer.path);
  for (final file in [
    'integration/primitives.mjs',
    'typescript/contracts.mts',
  ]) {
    await File('$root/test/$file')
        .copy('${consumer.path}/${file.split('/').last}');
  }
  for (final runtime in [node, bun]) {
    await run(runtime, ['primitives.mjs'], consumer.path);
    await run(runtime, [
      '$root/test/integration/bootstrap_failures.mjs',
      '${package.path}/bootstrap.mjs',
    ], consumer.path);
    await run(runtime, [
      '$root/test/integration/import_failures.mjs',
      package.path,
    ], consumer.path);
  }
  for (final resolution in ['NodeNext', 'Bundler']) {
    await run(tsc, [
      '--strict',
      '--noEmit',
      '--target',
      'ES2022',
      '--module',
      resolution == 'NodeNext' ? 'NodeNext' : 'ESNext',
      '--moduleResolution',
      resolution,
      'contracts.mts',
    ], consumer.path);
  }
}
