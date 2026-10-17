import 'dart:convert';
import 'dart:io';

import 'package:napi/build.dart';

/// Verify real build -> fresh npm package -> pack -> relocated install.
Future<void> verifyPackageAssembly(Directory root) async {
  final canonical = Directory(await root.resolveSymbolicLinks());
  final packaged = await buildPackage(
    library: File('test/compiler/package_assembly_fixtures.dart').absolute.uri,
    output: Directory('${canonical.path}/npm package'),
    packagesPath: File('.dart_tool/package_config.json').absolute.path,
    metadata: {
      'name': '@napi/path',
      'version': '0.0.0',
      'description': 'Fresh relocated Wasm package conformance fixture',
      'license': 'MIT',
      'author': {'name': 'Fixture Author', 'email': 'fixture@example.invalid'},
      'contributors': ['Fixture Contributor'],
    },
    assets: {'LICENSE': File('LICENSE')},
  );
  final pack = await Process.run('npm', [
    'pack',
    '--ignore-scripts',
    '--json',
    '--cache',
    '${canonical.path}/npm cache',
  ], workingDirectory: packaged.path);
  if (pack.exitCode != 0) {
    throw StateError('npm pack failed: ${pack.stdout}${pack.stderr}');
  }
  final packed = (jsonDecode(pack.stdout as String) as List).single as Map;
  final filename = packed['filename'] as String;
  final relocated = await Directory('${canonical.path}/relocated tarball space')
      .create();
  final archive = await File('${packaged.path}/$filename')
      .copy('${relocated.path}/$filename');
  // Prove installed imports cannot find the compiler's old build directories.
  await packaged.delete(recursive: true);
  final consumer = await Directory('${canonical.path}/fresh consumer space 雪')
      .create();
  await File('${consumer.path}/package.json')
      .writeAsString('{"private":true,"type":"module"}');
  await _run('npm', [
    'install',
    '--offline',
    '--ignore-scripts',
    '--no-audit',
    '--no-fund',
    '--cache',
    '${canonical.path}/npm cache',
    archive.path,
  ], cwd: consumer.path);
  await File('${consumer.path}/test.mjs').writeAsString('''
import assert from 'node:assert/strict';
import {add, optional, echo} from '@napi/path';
import {add as subpath, optional as subOptional} from '@napi/path/module.wasm';
import {add as relative} from './node_modules/@napi/path/module.wasm';
assert.equal(add, relative);
assert.equal(add, subpath);
assert.equal(optional, subOptional);
assert(import.meta.resolve('@napi/path').endsWith('/module.wasm'));
assert(import.meta.resolve('@napi/path/module.wasm').endsWith('/module.wasm'));
assert.equal(add(10, 32), 42);
assert.equal(optional(), 42);
assert.equal(optional(undefined), 42);
assert.equal(optional(0), 0);
assert.equal(echo('雪\\u0000\\ud800🙂'), '雪\\u0000\\ud800🙂');
assert.throws(() => add('1', 2), TypeError);
console.log('Fresh assembled npm package root/subpath and relocation: passed');
''');
  await File('${consumer.path}/consumer.mts').writeAsString('''
import {add, optional, echo} from '@napi/path';
import {add as subpath, optional as subOptional} from '@napi/path/module.wasm';
const number: number = add(subpath(1, 2), optional());
const text: string = echo(String(number));
const defaults: number = subOptional(undefined);
// @ts-expect-error required arguments stay required through package exports
add(1);
// @ts-expect-error scalar types stay exact through the wasm subpath
subpath('1', 2);
// @ts-expect-error optional argument does not accept null
optional(null);
// @ts-expect-error callable globals are not constructors
new subOptional();
void text; void defaults;
''');
  await _run('node', ['test.mjs'], cwd: consumer.path);
  final tsc = File(
    Platform.environment['NAPI_TSC'] ??
        '${Directory.current.path}/.dart_tool/js/node_modules/typescript/bin/tsc',
  ).absolute;
  if (!await tsc.exists()) {
    throw StateError(
      'Install TypeScript under .dart_tool/js, or set NAPI_TSC.',
    );
  }
  for (final mode in ['NodeNext', 'Bundler']) {
    await _run('node', [
      tsc.path,
      '--ignoreConfig',
      '--strict',
      '--exactOptionalPropertyTypes',
      '--noEmit',
      '--target',
      'ES2022',
      '--module',
      mode == 'NodeNext' ? 'NodeNext' : 'ESNext',
      '--moduleResolution',
      mode,
      '--allowArbitraryExtensions',
      'consumer.mts',
    ], cwd: consumer.path);
  }
}

Future<void> _run(
  String command,
  List<String> args, {
  required String cwd,
}) async {
  final result = await Process.run(command, args, workingDirectory: cwd);
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) {
    throw StateError('$command ${args.join(' ')} exited ${result.exitCode}');
  }
}

Future<void> main(List<String> args) async {
  final root = args.isEmpty
      ? await Directory('.dart_tool').createTemp('package assembly ')
      : await Directory(args.single).create(recursive: true);
  await verifyPackageAssembly(root);
  stdout.writeln('Wasm npm package assembly passed. Artifacts: ${root.path}');
}
