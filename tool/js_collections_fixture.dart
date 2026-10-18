import 'dart:convert';
import 'dart:io';

import 'verify.dart' show run;

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
  ];
  const bigints = ['bigBooleans', 'int64', 'intKey', 'wrongPolicy'];
  await File('${project.path}/build.dart').writeAsString('''
import 'dart:io';
import 'package:napi/build.dart';
import 'package:napi/napi.dart';
Future<void> main() async {
  for (final directory in ['package', 'external', 'nested']) {
    final external = directory != 'package';
    await buildPackage(
      library: File('business.dart').absolute.uri,
      output: Directory(directory),
      metadata: {'name': '@napi/js-collections-\${directory == 'package' ? 'fixture' : directory}', 'version': '0.0.0'},
      packagesPath: File('.dart_tool/package_config.json').absolute.path,
      external: external ? ExternalLibrary([
        if (directory == 'external') ...const [
          ${functions.map((name) => "ExternalFunction('$name'),").join('\n          ')}
          ${bigints.map((name) => "ExternalFunction('$name', config: NAPI(bigint: true)),").join('\n          ')}
          ExternalClass('Holder'),
          ExternalClass('ArrayPayloads'),
          ExternalClass('MapPayloads'),
          ExternalClass('Owner', config: NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')),
        ] else ...const [
          ExternalFunction('read'),
          ExternalFunction('write'),
          ExternalFunction('entered'),
        ],
        ${nestedFunctions.map((name) => "const ExternalFunction('$name'),").join('\n        ')}
        const ExternalFunction('nestedWrongPolicy', config: NAPI(bigint: true)),
        const ExternalClass('NestedValue', config: NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new')),
        const ExternalClass('NestedCapture', config: NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new')),
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
  final tsc =
      Platform.environment['NAPI_TSC'] ??
      '${Directory.current.path}/.dart_tool/js/node_modules/typescript/bin/tsc';
  for (final mode in ['NodeNext', 'Bundler']) {
    for (final exact in ['true', 'false']) {
      for (final unchecked in ['true', 'false']) {
        await run('node', [
          File(tsc).absolute.path,
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
  stdout.writeln(
    'JS collections $backend fresh consumer passed: ${consumer.path}',
  );
}

Future<void> main(List<String> args) async {
  if (args.length > 1) {
    throw ArgumentError(
      'Usage: dart run tool/js_collections_fixture.dart [native-runtime-bundle]',
    );
  }
  final root = await Directory('.dart_tool').createTemp('napi js collections ');
  stdout.writeln('JS collection artifacts: ${root.absolute.path}');
  await verifyJsCollectionsFixture(
    root,
    nativeRuntime: args.isEmpty ? null : Directory(args.single),
  );
}
