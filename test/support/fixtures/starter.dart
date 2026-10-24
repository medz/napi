import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../commands.dart';
import '../process.dart';

Future<void> verifyStarter(Directory root, {Directory? nativeRuntime}) async {
  final archive = '${root.path}/napi-starter.zip';
  await run('python3', ['tool/starter.py', archive]);
  await run('python3', ['-m', 'zipfile', '-e', archive, root.path]);
  final project = Directory('${root.path}/napi-starter');
  final manifest = await File('${project.path}/pubspec.yaml').readAsString();
  final version = RegExp(
    r'^version: (.+)$',
    multiLine: true,
  ).firstMatch(await File('pubspec.yaml').readAsString())!.group(1)!;
  expect(manifest, contains('napi: ^$version'));
  expect(manifest, isNot(contains('path:')));
  await File('${project.path}/pubspec_overrides.yaml').writeAsString('''
dependency_overrides:
  napi:
    path: ${jsonEncode(Directory.current.path)}
''');
  await runProcess(
    Platform.resolvedExecutable,
    ['pub', 'get', '--offline'],
    workingDirectory: project.path,
    timeout: const Duration(minutes: 1),
  );
  final script = await File('${project.path}/tool/build.dart')
      .rename('${project.path}/tool/compile.dart');
  if (nativeRuntime != null) {
    await script.writeAsString(
      (await script.readAsString()).replaceFirst(
        'final package = PackageBuild(',
        'final package = PackageBuild(\n'
            '  nativeRuntime: Directory(${jsonEncode(nativeRuntime.path)}),',
      ),
    );
  }
  await runProcess(
    Platform.resolvedExecutable,
    [
      'run',
      'tool/compile.dart',
      if (nativeRuntime != null) ...['--target', 'native'],
    ],
    workingDirectory: project.path,
    timeout: const Duration(minutes: 2),
  );
  await run('npm', [
    'install',
    '--offline',
    '--ignore-scripts',
    '--no-audit',
    '--no-fund',
    './npm-package',
  ], cwd: project.path);
  for (final node in nodeExecutables()) {
    final result = await runProcess(
      node,
      ['example.mjs'],
      workingDirectory: project.path,
      timeout: const Duration(seconds: 30),
    );
    expect(result.stdout.toString().trim().split(RegExp(r'\r?\n')), ['1', '3']);
  }
  await File('${project.path}/consumer.mts').writeAsString('''
import {Counter} from 'dart-counter';
const count: number = new Counter(1).increment(2);
// @ts-expect-error Counter takes a number.
new Counter('one');
void count;
''');
  await typescript(project, 'consumer.mts');
}
