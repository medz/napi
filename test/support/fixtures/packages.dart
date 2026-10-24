import 'dart:convert';
import 'dart:io';

import 'package:napi/build.dart';
import 'package:napi/src/build/publish.dart' show checkPackageRebuildFilesystem;

import 'package_contents.dart';
import '../commands.dart';

/// Verify real build -> fresh npm package -> pack -> relocated install.
Future<void> verifyPackageAssembly(Directory root) async {
  final canonical = Directory(await root.resolveSymbolicLinks());
  // This fixture's optional argument requires the callable Wasm assets.
  const expectedFiles = {
    'package.json',
    'module.wasm',
    'module.d.wasm.ts',
    'host.mjs',
    'boundary.mjs',
    'core.wasm',
    'calls.mjs',
    'references.mjs',
    'browser.mjs',
    'browser.d.mts',
    'browser-core.mjs',
    'browser-boundary.mjs',
    'browser-calls.mjs',
    'browser-references.mjs',
    'DART_LICENSE',
    'LICENSE',
  };
  final notices = {
    'DART_LICENSE': await File(
      '${File(Platform.resolvedExecutable).parent.parent.path}/LICENSE',
    ).readAsBytes(),
    'LICENSE': await File('LICENSE').readAsBytes(),
  };
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
  Directory? rebuiltModule;
  var rebuild = true;
  try {
    checkPackageRebuildFilesystem(packaged);
  } on UnsupportedError catch (error) {
    stdout.writeln('Managed rebuild skipped: $error');
    rebuild = false;
  }
  if (rebuild) {
    // Reuse the real compiler output: exercise replacement and npm exclusion
    // without compiling the same fixture twice.
    rebuiltModule = await Directory('${canonical.path}/rebuild input').create();
    for (final name in expectedFiles.difference({'package.json', 'LICENSE'})) {
      await File('${packaged.path}/$name').copy('${rebuiltModule.path}/$name');
    }
    await File('${packaged.path}/author-notes.txt')
        .writeAsString('keep locally');
    await assembleWasmPackage(
      module: BuiltModule(rebuiltModule, '3.13.5'),
      output: packaged,
      metadata: {'name': '@napi/path', 'version': '0.0.1'},
    );
    // One additional real Wasm compilation covers the high-level successful
    // rebuild: its held lock, compiler scratch, shared update and cleanup.
    await buildPackage(
      library: File('test/compiler/package_assembly_fixtures.dart')
          .absolute
          .uri,
      output: packaged,
      packagesPath: File('.dart_tool/package_config.json').absolute.path,
      metadata: {'name': '@napi/path', 'version': '0.0.2'},
    );
    final rebuilt = jsonDecode(
      await File('${packaged.path}/package.json').readAsString(),
    ) as Map;
    if (rebuilt['author'] is! Map ||
        rebuilt['version'] != '0.0.2' ||
        await File('${packaged.path}/author-notes.txt').readAsString() !=
            'keep locally') {
      throw StateError('Managed rebuild lost author content or metadata.');
    }
  }
  final pack = await npm([
    'pack',
    '--ignore-scripts',
    '--json',
    '--cache',
    '${canonical.path}/npm cache',
  ], cwd: packaged.path);
  if (pack.exitCode != 0) {
    throw StateError('npm pack failed: ${pack.stdout}${pack.stderr}');
  }
  final packed =
      (jsonDecode(pack.stdout as String) as List).single
          as Map<String, dynamic>;
  verifyPackedFiles(packed, expectedFiles);
  final filename = packed['filename'] as String;
  final relocated = await Directory('${canonical.path}/relocated tarball space')
      .create();
  final archive = await File('${packaged.path}/$filename')
      .copy('${relocated.path}/$filename');
  // Prove installed imports cannot find the compiler's old build directories.
  await packaged.delete(recursive: true);
  await rebuiltModule?.delete(recursive: true);
  final consumer = await Directory('${canonical.path}/fresh consumer space 雪')
      .create();
  await File('${consumer.path}/package.json')
      .writeAsString('{"private":true,"type":"module"}');
  await run('npm', [
    'install',
    '--offline',
    '--ignore-scripts',
    '--no-audit',
    '--no-fund',
    '--cache',
    '${canonical.path}/npm cache',
    archive.path,
  ], cwd: consumer.path);
  await verifyInstalledPackage(
    Directory('${consumer.path}/node_modules/@napi/path'),
    expectedFiles,
    notices,
  );
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
import {add as relative, optional as relativeOptional, echo as relativeEcho}
  from './node_modules/@napi/path/module.wasm';
const number: number = add(subpath(1, 2), optional());
const text: string = echo(String(number));
const defaults: number = subOptional(undefined);
const relativeResult: number = relative(number, relativeOptional());
const relativeDefaults: number = relativeOptional(undefined);
const relativeText: string = relativeEcho(text);
// @ts-expect-error required arguments stay required through package exports
add(1);
// @ts-expect-error scalar types stay exact through the wasm subpath
subpath('1', 2);
// @ts-expect-error optional argument does not accept null
optional(null);
// @ts-expect-error callable globals are not constructors
new subOptional();
// @ts-expect-error relative Wasm imports retain required argument presence
relative(1);
// @ts-expect-error relative Wasm imports retain strict scalar types
relative('1', 2);
// @ts-expect-error relative optional arguments do not accept null
relativeOptional(null);
// @ts-expect-error relative callable globals are not constructors
new relativeOptional();
void [text, defaults, relativeResult, relativeDefaults, relativeText];
''');
  await run('node', ['test.mjs'], cwd: consumer.path);
  await typescript(consumer, 'consumer.mts');
}
