import 'dart:convert';
import 'dart:io';

import 'package:napi/build.dart';
import 'package:path/path.dart' as path;

/// Build and install equivalent small APIs before measuring their consumers.
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    throw ArgumentError(
      'Usage: dart run tool/benchmark.dart <output> [node ...]',
    );
  }
  final output = Directory(args.first).absolute;
  if (await FileSystemEntity.type(output.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw ArgumentError('Benchmark output already exists: ${output.path}');
  }
  final nodes = args.length == 1 ? ['node'] : args.skip(1).toList();
  final versions = <String, String>{};
  for (final node in nodes) {
    versions[node] = (await command(node, ['--version'])).trim();
  }
  final rust = Directory('tool/benchmark/rust').absolute;
  final cli = File('${rust.path}/node_modules/@napi-rs/cli/dist/cli.js');
  if (!cli.existsSync()) {
    throw StateError('Run npm ci --prefix tool/benchmark/rust first.');
  }
  final rustVersion = (await command('rustc', ['--version'])).trim();
  await output.create(recursive: true);
  final packages = <String, Directory>{};
  for (final target in BuildTarget.values) {
    packages[target.name] = await buildPackage(
      library: File('tool/benchmark/api.dart').absolute.uri,
      output: Directory('${output.path}/${target.name}'),
      packagesPath: File('.dart_tool/package_config.json').absolute.path,
      metadata: {'name': '@napi/benchmark-${target.name}', 'version': '0.0.0'},
      target: target,
    );
  }
  final rustPackage = await Directory('${output.path}/napi-rs').create();
  await command(nodes.first, [
    cli.path,
    'build',
    '--release',
    '--platform',
    '--output-dir',
    rustPackage.path,
    '--target-dir',
    '${output.path}/cargo-target',
  ], cwd: rust.path);
  await File('${rust.path}/package.json')
      .copy('${rustPackage.path}/package.json');
  await File('LICENSE').copy('${rustPackage.path}/LICENSE');
  packages['napi-rs'] = rustPackage;
  final runtime = jsonDecode(
    await File('${packages['native']!.path}/runtime.json').readAsString(),
  ) as Map;
  final data = <String, Object?>{
    'timestampUtc': DateTime.now().toUtc().toIso8601String(),
    'platform': Platform.operatingSystem,
    'osVersion': Platform.operatingSystemVersion,
    'dart': Platform.version,
    'rust': rustVersion,
    'nativeRuntime': {'identity': runtime['identity'], 'abi': runtime['abi']},
    'napiRsCli': (jsonDecode(
      await File('${rust.path}/node_modules/@napi-rs/cli/package.json')
          .readAsString(),
    ) as Map)['version'],
    'gitCommit': (await command('git', ['rev-parse', 'HEAD'])).trim(),
    'packages': <String, Object?>{},
    'samples': <Object?>[],
  };
  final entries = <String, String>{};
  for (final entry in packages.entries) {
    final packed =
        (jsonDecode(
              await command('npm', [
                'pack',
                '--json',
                '--ignore-scripts',
                '--offline',
              ], cwd: entry.value.path),
            ) as List).single
            as Map;
    final consumer = await Directory('${output.path}/consumer-${entry.key}')
        .create();
    await File('${consumer.path}/package.json')
        .writeAsString('{"private":true}');
    await command('npm', [
      'install',
      '--offline',
      '--ignore-scripts',
      '--no-audit',
      '--no-fund',
      '${entry.value.path}/${packed['filename']}',
    ], cwd: consumer.path);
    final installed = Directory(
      '${consumer.path}/node_modules/${packed['name']}',
    );
    final manifest = jsonDecode(
      await File('${installed.path}/package.json').readAsString(),
    ) as Map;
    final entrypoint = entry.key == 'napi-rs'
        ? manifest['main'] as String
        : ((manifest['exports'] as Map)['.'] as Map)['import'] as String;
    entries[entry.key] = path.join(installed.path, entrypoint);
    var installedBytes = 0;
    await for (final file in installed.list(
      recursive: true,
      followLinks: false,
    )) {
      if (file is File) installedBytes += await file.length();
    }
    (data['packages'] as Map)[entry.key] = {
      'tarballBytes': packed['size'],
      'unpackedBytes': packed['unpackedSize'],
      'installedBytes': installedBytes,
    };
  }
  final report = File('${output.path}/results.json');
  Future<void> save() => report.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(data)}\n',
  );
  await save();
  final probe = File('tool/benchmark/measure.mjs').absolute.path;
  for (final node in nodes) {
    // Rotate order across fresh processes; do not time builds or npm installs.
    for (var round = 0; round < 3; round++) {
      final targets = entries.keys.toList();
      for (var index = 0; index < targets.length; index++) {
        final target = targets[(round + index) % targets.length];
        final sample = jsonDecode(
          await command(node, ['--expose-gc', probe, entries[target]!, target]),
        ) as Map;
        (data['samples'] as List).add({
          'target': target,
          'round': round,
          ...sample,
        });
        await save();
        stdout.writeln(
          '${versions[node]} $target: ${sample['importMs']} ms import',
        );
      }
    }
  }
  stdout.writeln('Saved ${report.path}');
}

Future<String> command(
  String executable,
  List<String> args, {
  String? cwd,
}) async {
  final result = await Process.run(
    executable,
    args,
    workingDirectory: cwd,
    runInShell: Platform.isWindows && executable == 'npm',
  );
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      args,
      '${result.stdout}\n${result.stderr}',
      result.exitCode,
    );
  }
  return result.stdout as String;
}
