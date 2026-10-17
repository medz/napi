import 'dart:convert';
import 'dart:io';

import 'package:napi/build.dart';

import 'verify.dart' show run, typescript;
import 'value_fixture.dart';

Future<void> verifyClassFixture(Directory root) async {
  final canonical = await Directory(root.resolveSymbolicLinksSync())
      .createTemp('generated ');
  final project = await Directory('${canonical.path}/business').create();
  await File('${project.path}/pubspec.yaml').writeAsString('''
name: wasm_class_business
environment:
  sdk: ^3.13.5
dependencies:
  napi:
    path: ${jsonEncode(Directory.current.path)}
''');
  await File('test/fixtures/value_classes.dart')
      .copy('${project.path}/business.dart');
  await File('test/fixtures/dictionaries.dart')
      .copy('${project.path}/dictionaries.dart');
  await File('test/fixtures/maps.dart').copy('${project.path}/maps.dart');
  await File('test/fixtures/classes.dart').copy('${project.path}/classes.dart');
  await File('test/fixtures/reference_hierarchy.dart')
      .copy('${project.path}/reference_hierarchy.dart');
  await File('test/fixtures/reference_views.dart')
      .copy('${project.path}/reference_views.dart');
  await File('${project.path}/build.dart').writeAsString('''
import 'dart:io';
import 'package:napi/build.dart';
Future<void> main() async {
  final built = await buildLibrary(
    library: File('business.dart').absolute.uri,
    output: Directory('built'),
    packagesPath: File('.dart_tool/package_config.json').absolute.path,
  );
  await assembleWasmPackage(module: built, output: Directory('package'),
    metadata: {'name': '@napi/class-fixture', 'version': '0.0.0'});
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
    '${project.path}/package/napi-class-fixture-0.0.0.tgz',
  ).copy('${canonical.path}/classes.tgz');
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
  await File('test/integration/classes.mjs').copy('${consumer.path}/test.mjs');
  await File('test/integration/class_contract.mjs')
      .copy('${consumer.path}/class_contract.mjs');
  await File('test/integration/hierarchy_contract.mjs')
      .copy('${consumer.path}/hierarchy_contract.mjs');
  await File('test/integration/reference_views_contract.mjs')
      .copy('${consumer.path}/reference_views_contract.mjs');
  await File('test/integration/reference_contract.mjs')
      .copy('${consumer.path}/reference_contract.mjs');
  await File('test/integration/structural_reference_contract.mjs')
      .copy('${consumer.path}/structural_reference_contract.mjs');
  await File('test/integration/map_contract.mjs')
      .copy('${consumer.path}/map_contract.mjs');
  await File('test/integration/dictionary_contract.mjs')
      .copy('${consumer.path}/dictionary_contract.mjs');
  await File('test/integration/value_class_contract.mjs')
      .copy('${consumer.path}/value_class_contract.mjs');
  await File('test/typescript/value_classes.mts')
      .copy('${consumer.path}/value_classes.mts');
  await File('test/typescript/dictionaries.mts')
      .copy('${consumer.path}/dictionaries.mts');
  await File('test/typescript/maps.mts').copy('${consumer.path}/maps.mts');
  await File('test/typescript/classes.mts')
      .copy('${consumer.path}/consumer.mts');
  await run('node', ['--expose-gc', 'test.mjs'], cwd: consumer.path);
  await typescript(consumer, 'consumer.mts');
  await typescript(consumer, 'maps.mts');
  await typescript(consumer, 'dictionaries.mts');
  await typescript(consumer, 'value_classes.mts');
  await File('test/typescript/reference_hierarchy.mts')
      .copy('${consumer.path}/reference_hierarchy.mts');
  await typescript(consumer, 'reference_hierarchy.mts');
  await File('test/typescript/reference_views.mts')
      .copy('${consumer.path}/reference_views.mts');
  await typescript(consumer, 'reference_views.mts');

  // External metadata must work without source annotations.
  final plain = await File('test/fixtures/classes.dart').readAsString();
  final source = await File('${canonical.path}/plain.dart').writeAsString(
    plain
        .replaceAll(RegExp(r'^\s*@NAPI\([^\n]*\)\s*\n', multiLine: true), '')
        .replaceAll("import 'package:napi/napi.dart';", ''),
  );
  final external = await buildLibrary(
    library: source.uri,
    output: Directory('${canonical.path}/external'),
    packagesPath: File('.dart_tool/package_config.json').absolute.path,
    external: const ExternalLibrary([
      ExternalFunction('liveCounters'),
      ExternalFunction('referenceConstructions'),
      ExternalFunction('identityBase'),
      ExternalFunction('identityReference'),
      ExternalFunction('nullableReference'),
      ExternalFunction('optionalReference'),
      ExternalFunction('namedReference'),
      ExternalFunction('holdReference'),
      ExternalFunction('heldReference'),
      ExternalFunction('referenceAlive'),
      ExternalFunction('referencePressure'),
      ExternalFunction('structuralReferenceCalls'),
      ExternalFunction('echoReferenceRows'),
      ExternalFunction('holdReferenceRows'),
      ExternalFunction('heldReferenceRows'),
      ExternalFunction('invalidReferenceRow'),
      ExternalFunction('mixedReferenceRows'),
      ExternalFunction('failingReferenceList'),
      ExternalFunction('failingReferenceScalar'),
      ExternalFunction('partialReferenceChild'),
      ExternalFunction('createPartialReferenceBase'),
      ExternalFunction('failingExistingReferenceScalar'),
      ExternalClass(
        'RefCollection',
        members: [
          ExternalMember.method('echo', config: NAPI(name: 'duplicate')),
        ],
      ),
      ExternalClass(
        'RefBox',
        members: [
          ExternalMember.constructor('named', config: NAPI(name: 'from')),
        ],
      ),
      ExternalClass('Once'),
      ExternalClass('NamedReference'),
      ExternalClass('RefBase'),
      ExternalClass('RefChild'),
      ExternalClass(
        'Counter',
        members: [
          ExternalMember.method('twice', config: NAPI(name: 'doubleValue')),
          ExternalMember.method('hidden', config: NAPI(exclude: true)),
        ],
      ),
      ExternalClass('Other'),
      ExternalClass(
        'Scalars',
        members: [
          ExternalMember.method('buildTag', config: NAPI(name: 'constructor')),
        ],
      ),
      ExternalClass('Options'),
    ]),
  );
  await File('test/integration/class_contract.mjs')
      .copy('${external.directory.path}/class_contract.mjs');
  await File('test/integration/reference_contract.mjs')
      .copy('${external.directory.path}/reference_contract.mjs');
  await File('test/integration/structural_reference_contract.mjs')
      .copy('${external.directory.path}/structural_reference_contract.mjs');
  await File('${external.directory.path}/test.mjs').writeAsString('''
import * as api from './module.wasm';
import {verifyClasses} from './class_contract.mjs';
import {verifyReferences} from './reference_contract.mjs';
import {verifyStructuralReferences} from './structural_reference_contract.mjs';
verifyClasses(api);
verifyReferences(api);
verifyStructuralReferences(api);
console.log('External unannotated Wasm classes: passed');
''');
  await run('node', ['--expose-gc', 'test.mjs'], cwd: external.directory.path);
  final only = await buildLibrary(
    library: source.uri,
    output: Directory('${canonical.path}/class only'),
    packagesPath: File('.dart_tool/package_config.json').absolute.path,
    external: const ExternalLibrary([
      ExternalClass('Other', config: NAPI(name: 'globalThis')),
    ]),
  );
  await File('${only.directory.path}/test.mjs').writeAsString('''
import assert from 'node:assert/strict';
import {globalThis as Other} from './module.wasm';
assert.equal(new Other(42).value, 42);
console.log('Class-only Wasm module with renamed export: passed');
''');
  await run('node', ['test.mjs'], cwd: only.directory.path);
  await verifyValueOnlyFixture(root);
  stdout.writeln('Generated Wasm classes and fresh package: passed');
}

Future<void> main(List<String> args) async {
  final root = args.isEmpty
      ? await Directory('.dart_tool').createTemp('classes ')
      : await Directory(args.single).create(recursive: true);
  await verifyClassFixture(root);
}
