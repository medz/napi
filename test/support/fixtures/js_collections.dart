import 'dart:convert';
import 'dart:io';

import '../commands.dart' show run, typecheck;

/// Build once per backend, then verify relocated annotation/external packages.
Future<void> verifyJsCollectionsFixture(
  Directory root, {
  Directory? nativeRuntime,
}) async {
  final native = nativeRuntime != null;
  final backend = native ? 'native' : 'wasm';
  final canonical = await Directory(root.resolveSymbolicLinksSync())
      .createTemp('js collections $backend 雪 ');
  final project = await Directory('${canonical.path}/business 中文').create();
  await File('${project.path}/pubspec.yaml').writeAsString('''
name: js_collections_business
environment:
  sdk: ^3.13.5
dependencies:
  napi:
    path: ${jsonEncode(Directory.current.path)}
''');
  await File('test/fixtures/js_collections.dart')
      .copy('${project.path}/business.dart');
  await File('test/fixtures/js_value_collections.dart')
      .copy('${project.path}/js_value_collections.dart');
  const nestedFunctions = [
    'nested',
    'nestedAccess',
    'nestedLater',
    'nestedEvents',
    'nestedPayloads',
    'nestedValue',
    'nestedCaptured',
    'nestedFake',
    'nestedOrder',
  ];
  const functions = [
    'remember',
    'same',
    'alive',
    'drop',
    'pressure',
    'length',
    'read',
    'write',
    'caught',
    'delayedRead',
    'optional',
    'named',
    'nullable',
    'booleans',
    'strings',
    'doubles',
    'bigints',
    'partial',
    'entered',
    'later',
    'hold',
    'complete',
    'events',
    'rememberMap',
    'sameMap',
    'mapAlive',
    'size',
    'has',
    'get',
    'put',
    'remove',
    'clear',
    'iterate',
    'next',
    'doubleKey',
    'bigKey',
    'nullKey',
    'laterMap',
    'mapEvents',
    'copied',
    'fake',
    'renamedPolicy',
    'numberPolicy',
    'nullablePayload',
    'nullableMapPayload',
    'stringPayload',
    'keyedScalar',
    'firstPayload',
    'firstScalar',
    'nestedNumbers',
    'nestedFakeWrite',
    'nestedCallback',
    'nestedAsyncCallback',
    'nestedReference',
    'referenceCallback',
    'referenceBox',
    'concreteReference',
    'writeReferenceResource',
    'writeConflictingResource',
    'collectionCleanups',
    'collectionEvents',
    'collectionWaiting',
    'collectionComplete',
    'collectionTimers',
    'collectionTimerResult',
    'nestedBinary',
    'nestedBuffer',
    'binaryCallback',
    'copiedBinaryKey',
    'nullableBinaryKey',
    'binarySharedPolicy',
    'structuralKeys',
    'recordKey',
    'containerKeys',
    'containerKeyRecords',
    'containerKeyCopies',
    'containerKeyCallback',
    'recordMapCollision',
    'structuralCallback',
    'structuralWideBigints',
    'mixedResourceEntries',
    'pureCopiedPayload',
    'collectionValueConstructions',
    'collectionValueCleanups',
    'collectionReject',
  ];
  const bigints = [
    'bigBooleans',
    'int64',
    'intKey',
    'wrongPolicy',
    'nestedInt64',
    'nestedWriteWrongPolicy',
    'structuralBigints',
  ];
  await File('${project.path}/build.dart').writeAsString('''
import 'dart:io';
import 'package:napi/build.dart';
import 'package:napi/napi.dart';
Future<void> main() async {
  for (final directory in ['package', 'external', 'nested', 'copied']) {
    final external = directory != 'package';
    await buildPackage(
      library: File('business.dart').absolute.uri,
      output: Directory(directory),
      metadata: {'name': '@napi/js-collections-\${directory == 'package' ? 'fixture' : directory}', 'version': '0.0.0'},
      packagesPath: File('.dart_tool/package_config.json').absolute.path,
      external: directory == 'copied' ? const ExternalLibrary([
        ExternalFunction('pureCopiedPayload'),
      ]) : external ? ExternalLibrary([
        if (directory == 'external') ...const [
          ${functions.map((name) => "ExternalFunction('$name'),").join('\n          ')}
          ${bigints.map((name) => "ExternalFunction('$name', config: NAPI(bigint: true)),").join('\n          ')}
          ExternalClass('Holder'),
          ExternalClass('ContainerKeyMaps'),
          ExternalClass('ArrayPayloads'),
          ExternalClass('MapPayloads'),
          ExternalClass('NestedArrays'),
          ExternalClass('NestedMaps'),
          ExternalClass('RefItem'),
          ExternalClass('RefChild'),
          ExternalClass('OtherItem'),
          ExternalClass('ReferenceCollections'),
          ExternalClass('RefBox'),
          ExternalClass('IntItem'),
          ExternalClass('TextItem'),
          ExternalClass('ResourceItem', config: NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')),
          ExternalClass('OtherResource', config: NAPI(classPolicy: ClassPolicy.resource, cleanup: 'release')),
          ExternalClass('ResourceCollections'),
          ExternalClass('BinaryCollections'),
          ExternalClass('SharedByteCollections'),
          ExternalClass('StructuralCollections'),
          ExternalClass('CopiedPayloads'),
          ExternalClass('CopiedResources'),
          ExternalClass('CollectionValue', config: NAPI(classPolicy: ClassPolicy.value), members: [
            ExternalMember.getter('hashCode', config: NAPI(exclude: true)),
          ]),
          ExternalClass('CollectionParsed', config: NAPI(classPolicy: ClassPolicy.value)),
          ExternalClass('CollectionNode', config: NAPI(classPolicy: ClassPolicy.value)),
          ExternalClass('CollectionOutput', config: NAPI(classPolicy: ClassPolicy.value)),
          ExternalClass('CollectionEnvelope', config: NAPI(classPolicy: ClassPolicy.value)),
          ExternalClass('CollectionEscaping', config: NAPI(classPolicy: ClassPolicy.value)),
          ExternalClass('CollectionRejecting', config: NAPI(classPolicy: ClassPolicy.value)),
          ExternalClass('CollectionResource', config: NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')),
          ExternalClass('CollectionResourceValue', config: NAPI(classPolicy: ClassPolicy.value)),
          ExternalClass('ValueCollectionOwner'),
          ExternalClass('Owner', config: NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')),
        ] else ...const [
          ExternalFunction('read'),
          ExternalFunction('write'),
          ExternalFunction('entered'),
        ],
        ${nestedFunctions.map((name) => "const ExternalFunction('$name'),").join('\n        ')}
        const ExternalFunction('nestedWrongPolicy', config: NAPI(bigint: true)),
        const ExternalClass('NestedValue', config: NAPI(classPolicy: ClassPolicy.value)),
        const ExternalClass('NestedCapture', config: NAPI(classPolicy: ClassPolicy.value)),
        const ExternalClass('NestedOutput', config: NAPI(classPolicy: ClassPolicy.value)),
      ]) : null,
      ${native ? 'target: BuildTarget.native,\n      nativeRuntime: Directory(${jsonEncode(nativeRuntime.absolute.path)}),' : ''}
    );
  }
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
  final declaration = native ? 'module.d.mts' : 'module.d.wasm.ts';
  if (await File('${project.path}/package/$declaration').readAsString() !=
      await File('${project.path}/external/$declaration').readAsString()) {
    throw StateError(
      'Annotation and external JS collection declarations differ.',
    );
  }
  final archives = <String>[];
  for (final (directory, name) in [
    ('package', 'fixture'),
    ('external', 'external'),
    ('nested', 'nested'),
    ('copied', 'copied'),
  ]) {
    final package = '${project.path}/$directory';
    await run('npm', ['pack', '--ignore-scripts', '--silent'], cwd: package);
    archives.add(
      (await File('$package/napi-js-collections-$name-0.0.0.tgz')
              .copy('${canonical.path}/$name.tgz'))
          .path,
    );
  }
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
    ...archives,
  ], cwd: consumer.path);
  await File('test/integration/js_collections.mjs')
      .copy('${consumer.path}/test.mjs');
  await run('node', ['--expose-gc', 'test.mjs'], cwd: consumer.path);
  final declarations = (await File(
    'test/typescript/js_collections.mts',
  ).readAsString()).replaceAll('/BACKEND', native ? '/native' : '/module.wasm');
  await File('${consumer.path}/consumer.mts').writeAsString(declarations);
  for (final mode in ['NodeNext', 'Bundler']) {
    for (final exact in ['true', 'false']) {
      for (final unchecked in ['true', 'false']) {
        await typecheck([
          '--ignoreConfig',
          '--strict',
          '--exactOptionalPropertyTypes',
          exact,
          '--noUncheckedIndexedAccess',
          unchecked,
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
  }
}
