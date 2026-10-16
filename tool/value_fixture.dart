import 'dart:convert';
import 'dart:io';

import 'verify.dart' show run, typescript;

/// Proves that a type-only library survives packaging and source removal.
/// The experimental Wasm SDK's support exports are not the public binding API.
Future<void> verifyValueOnlyFixture(
  Directory root, {
  Directory? nativeRuntime,
}) async {
  final native = nativeRuntime != null;
  final backend = native ? 'native' : 'wasm';
  final canonical = await Directory(root.resolveSymbolicLinksSync())
      .createTemp('value only $backend 雪 ');
  final project = await Directory('${canonical.path}/business 中文').create();
  await File('${project.path}/pubspec.yaml').writeAsString('''
name: value_only_business
environment:
  sdk: ^3.13.5
dependencies:
  napi:
    path: ${jsonEncode(Directory.current.path)}
''');
  await File('${project.path}/business.dart').writeAsString('''
import 'package:napi/napi.dart';
@NAPI(classPolicy: ClassPolicy.value)
class ValueOnly {
  final int value;
  final ValueOnly? next;
  const ValueOnly(this.value, this.next);
}
''');
  await File('${project.path}/build.dart').writeAsString('''
import 'dart:io';
import 'package:napi/build.dart';
Future<void> main() async {
  final module = await buildLibrary(
    library: File('business.dart').absolute.uri,
    output: Directory('built'),
    packagesPath: File('.dart_tool/package_config.json').absolute.path,
    ${native ? 'target: BuildTarget.native,\n    nativeRuntime: Directory(${jsonEncode(nativeRuntime.absolute.path)}),' : ''}
  );
  await ${native ? 'assembleNativePackage' : 'assembleWasmPackage'}(
    module: module,
    output: Directory('package'),
    metadata: {'name': '@napi/value-only-fixture', 'version': '0.0.0'},
  );
}
''');
  await run(Platform.resolvedExecutable, [
    'pub',
    'get',
    '--offline',
  ], cwd: project.path);
  await run(Platform.resolvedExecutable, [
    'run',
    'build.dart',
  ], cwd: project.path);
  await run('npm', [
    'pack',
    '--ignore-scripts',
    '--silent',
  ], cwd: '${project.path}/package');
  final archive = await File(
    '${project.path}/package/napi-value-only-fixture-0.0.0.tgz',
  ).copy('${canonical.path}/value-only.tgz');
  // Removing this owned directory also removes the original source, build and
  // assembled package. The consumer can use only the packed installation.
  await project.delete(recursive: true);
  final consumer = await Directory('${canonical.path}/installed consumer 雪')
      .create();
  await File('${consumer.path}/package.json')
      .writeAsString('{"private":true,"type":"module"}');
  await run('npm', [
    'install',
    '--offline',
    '--ignore-scripts',
    '--no-audit',
    '--no-fund',
    archive.path,
  ], cwd: consumer.path);
  final subpath = native ? 'native' : 'module.wasm';
  await File('${consumer.path}/test.mjs').writeAsString('''
import assert from 'node:assert/strict';
import {existsSync} from 'node:fs';
import * as api from '@napi/value-only-fixture';
import * as direct from '@napi/value-only-fixture/$subpath';
assert.equal(existsSync(${jsonEncode(project.path)}), false);
// A monolithic Dart Wasm module retains these SDK support exports. They are
// not public bindings and do not require an extra facade for a type-only module.
const sdkExports = new Set(${native ? '[]' : r'["$invokeMain", "$wasmI16ArrayGet", "$wasmI16ArraySet"]'});
assert.deepEqual(Object.keys(api).filter(name => !sdkExports.has(name)), []);
assert.deepEqual(Object.keys(direct).filter(name => !sdkExports.has(name)), []);
assert.equal(Object.hasOwn(api, 'ValueOnly'), false);
assert.equal(api, direct);
console.log('Type-only $backend installed module: no public runtime bindings or value constructors passed');
''');
  await File('${consumer.path}/consumer.mts').writeAsString('''
import {ValueOnly} from '@napi/value-only-fixture';
import type {ValueOnly as Direct} from '@napi/value-only-fixture/$subpath';
const leaf: ValueOnly = {value: 1, next: null};
const tree: Direct = {value: 2, next: leaf};
const number: number = tree.next!.value;
// @ts-expect-error a type-only value declaration has no JS constructor.
new ValueOnly(1, null);
// @ts-expect-error nullable output fields remain required.
const missing: ValueOnly = {value: 3};
// @ts-expect-error nullable output fields do not accept undefined.
const absent: ValueOnly = {value: 3, next: undefined};
// @ts-expect-error recursion preserves strict scalar types.
const wrong: Direct = {value: 3, next: {value: 'bad', next: null}};
void [tree, number, missing, absent, wrong];
''');
  await run('node', ['test.mjs'], cwd: consumer.path);
  await typescript(consumer, 'consumer.mts');
  stdout.writeln('Type-only $backend fresh package and TypeScript: passed');
}
