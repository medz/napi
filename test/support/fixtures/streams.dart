import 'dart:convert';
import 'dart:io';

import '../commands.dart' show run, typecheck;

/// Verifies generated stream declarations in relocated, installed packages.
Future<void> verifyStreamFixture(
  Directory root, {
  Directory? nativeRuntime,
}) async {
  final native = nativeRuntime != null;
  final backend = native ? 'native' : 'wasm';
  final canonical = await Directory(root.resolveSymbolicLinksSync())
      .createTemp('streams $backend 雪 ');
  final project = await Directory('${canonical.path}/business 中文').create();
  await File('${project.path}/pubspec.yaml').writeAsString('''
name: streams_business
environment:
  sdk: ^3.13.5
dependencies:
  napi:
    path: ${jsonEncode(Directory.current.path)}
''');
  await File('test/fixtures/streams.dart')
      .copy('${project.path}/business.dart');
  await File('${project.path}/build.dart').writeAsString('''
import 'dart:io';
import 'package:napi/build.dart';
import 'package:napi/napi.dart';
Future<void> main() async {
  for (final external in [false, true]) {
    await buildPackage(
      library: File('business.dart').absolute.uri,
      output: Directory(external ? 'external' : 'package'),
      metadata: {'name': external ? '@napi/streams-external' : '@napi/streams-fixture', 'version': '0.0.0'},
      packagesPath: File('.dart_tool/package_config.json').absolute.path,
      external: external ? const ExternalLibrary([
        ExternalFunction('streamCalls'),
        ExternalFunction('streamEvents'),
        ExternalFunction('releaseCancel'),
        ExternalFunction('emitHeld'),
        ExternalFunction('range'),
        ExternalFunction('generated'),
        ExternalFunction('voidItems'),
        ExternalFunction('echoItems'),
        ExternalFunction('textItems'),
        ExternalFunction('doubleItems'),
        ExternalFunction('wideItems', config: NAPI(bigint: true)),
        ExternalFunction('hugeItems'),
        ExternalFunction('unsafeItems'),
        ExternalFunction('sourceError'),
        ExternalFunction('callbackError'),
        ExternalFunction('pointItems'),
        ExternalFunction('rowItems'),
        ExternalFunction('mapItems'),
        ExternalFunction('holdInputs'),
        ExternalFunction('heldBoxAlive'),
        ExternalFunction('streamPressure'),
        ExternalFunction('compositeItems'),
        ExternalFunction('rightItems'),
        ExternalClass('StreamBox'),
        ExternalClass('StreamPoint', config: NAPI(classPolicy: ClassPolicy.value)),
        ExternalClass('IntFeed'),
        ExternalClass('OpaqueFeed'),
        ExternalClass('SnapshotFeed'),
        ExternalClass('StreamOwner', config: NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')),
        ExternalClass('StreamLeft'),
        ExternalClass('StreamRight'),
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
  final archives = <String>[];
  for (final (directory, name) in [
    ('package', 'fixture'),
    ('external', 'external'),
  ]) {
    final package = '${project.path}/$directory';
    await run('npm', ['pack', '--ignore-scripts', '--silent'], cwd: package);
    final archive = await File('$package/napi-streams-$name-0.0.0.tgz')
        .copy('${canonical.path}/$name.tgz');
    archives.add(archive.path);
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
  await File('test/integration/streams.mjs').copy('${consumer.path}/test.mjs');
  final declarations = await File('test/typescript/streams.mts').readAsString();
  await run('node', ['--expose-gc', 'test.mjs'], cwd: consumer.path);
  for (final mode in ['NodeNext', 'Bundler']) {
    for (final exact in ['true', 'false']) {
      await File('${consumer.path}/consumer.mts').writeAsString(
        declarations.replaceAll(
          '/BACKEND',
          native ? '/native' : '/module.wasm',
        ),
      );
      for (final strictFunctions in ['true', 'false']) {
        await typecheck([
          '--ignoreConfig',
          '--strict',
          '--exactOptionalPropertyTypes',
          exact,
          '--strictFunctionTypes',
          strictFunctions,
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
