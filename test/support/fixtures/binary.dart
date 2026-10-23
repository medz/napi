import 'dart:convert';
import 'dart:io';

import '../commands.dart' show run, typecheck;

/// Verifies generated binary snapshots and declarations in relocated, installed packages.
Future<void> verifyBinaryFixture(
  Directory root, {
  Directory? nativeRuntime,
}) async {
  final native = nativeRuntime != null;
  final backend = native ? 'native' : 'wasm';
  final canonical = await Directory(root.resolveSymbolicLinksSync())
      .createTemp('binary $backend 雪 ');
  final project = await Directory('${canonical.path}/business 中文').create();
  await File('${project.path}/pubspec.yaml').writeAsString('''
name: binary_business
environment:
  sdk: ^3.13.5
dependencies:
  napi:
    path: ${jsonEncode(Directory.current.path)}
''');
  await File('test/fixtures/binary.dart').copy('${project.path}/business.dart');
  await File('${project.path}/build.dart').writeAsString('''
import 'dart:io';
import 'package:napi/build.dart';
import 'package:napi/napi.dart';
Future<void> main() async {
  for (final external in [false, true]) {
    await buildPackage(
      library: File('business.dart').absolute.uri,
      output: Directory(external ? 'external' : 'package'),
      metadata: {'name': external ? '@napi/binary-external' : '@napi/binary-fixture', 'version': '0.0.0'},
      packagesPath: File('.dart_tool/package_config.json').absolute.path,
      external: external ? const ExternalLibrary([
        ExternalFunction('entries'),
        ExternalFunction('events'),
        ExternalFunction('bytes'),
        ExternalFunction('buffer'),
        ExternalFunction('nullable'),
        ExternalFunction('optional'),
        ExternalFunction('named'),
        ExternalFunction('requiredNamed'),
        ExternalFunction('opaque'),
        ExternalFunction('window'),
        ExternalFunction('windowBuffer'),
        ExternalFunction('empty'),
        ExternalFunction('repeated'),
        ExternalFunction('repeatedBuffers'),
        ExternalFunction('lists'),
        ExternalFunction('maps'),
        ExternalFunction('keyed'),
        ExternalFunction('dictionary'),
        ExternalFunction('record'),
        ExternalFunction('setConversion'),
        ExternalFunction('packet'),
        ExternalFunction('packets'),
        ExternalFunction('afterPacket'),
        ExternalFunction('hold'),
        ExternalFunction('complete'),
        ExternalFunction('futureBuffer'),
        ExternalFunction('futureWindow'),
        ExternalFunction('futureRows'),
        ExternalFunction('changeOutput'),
        ExternalFunction('pressure'),
        ExternalClass('BinaryKey', members: [
          ExternalMember.getter('hashCode', config: NAPI(exclude: true)),
        ]),
        ExternalClass('BinaryBox'),
        ExternalClass('Packet', config: NAPI(classPolicy: ClassPolicy.value)),
        ExternalClass('BinaryOwner', config: NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')),
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
    throw StateError('Annotation and external binary declarations differ.');
  }
  final archives = <String>[];
  for (final (directory, name) in [
    ('package', 'fixture'),
    ('external', 'external'),
  ]) {
    final package = '${project.path}/$directory';
    await run('npm', ['pack', '--ignore-scripts', '--silent'], cwd: package);
    final archive = await File('$package/napi-binary-$name-0.0.0.tgz')
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
  await File('test/integration/binary.mjs').copy('${consumer.path}/test.mjs');
  final declarations = await File('test/typescript/binary.mts').readAsString();
  await run('node', ['--expose-gc', 'test.mjs'], cwd: consumer.path);
  for (final mode in ['NodeNext', 'Bundler']) {
    for (final exact in ['true', 'false']) {
      await File('${consumer.path}/consumer.mts').writeAsString(
        declarations.replaceAll(
          '/BACKEND',
          native ? '/native' : '/module.wasm',
        ),
      );
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
