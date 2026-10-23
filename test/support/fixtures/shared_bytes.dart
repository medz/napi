import 'dart:convert';
import 'dart:io';

import '../commands.dart' show run, typecheck;

/// Verifies live shared byte views and declarations in relocated, installed packages.
Future<void> verifySharedBytesFixture(
  Directory root, {
  Directory? nativeRuntime,
}) async {
  final native = nativeRuntime != null;
  final backend = native ? 'native' : 'wasm';
  final canonical = await Directory(root.resolveSymbolicLinksSync())
      .createTemp('shared_bytes $backend 雪 ');
  final project = await Directory('${canonical.path}/business 中文').create();
  await File('${project.path}/pubspec.yaml').writeAsString('''
name: shared_bytes_business
environment:
  sdk: ^3.13.5
dependencies:
  napi:
    path: ${jsonEncode(Directory.current.path)}
''');
  await File('test/fixtures/shared_bytes.dart')
      .copy('${project.path}/business.dart');
  await File('${project.path}/internal.dart').writeAsString('''
import 'dart:typed_data';
import 'package:napi/napi.dart';
@NAPI() int defaults(int size) {
  final source = SharedBytes.allocate(size);
  final target = SharedBytes.allocate(size);
  source.write(Uint8List(size)..fillRange(0, size, 7));
  target.copyFrom(source);
  final snapshot = source.toUint8List();
  final explicit = source.toUint8List(0, null);
  final emptyCopy = source.toUint8List(size);
  final view = source.subview(0);
  final emptyView = source.subview(size, null);
  target.copyFrom(source, sourceOffset: size, targetOffset: size);
  return snapshot.length + explicit.length + emptyCopy.length + view.length + emptyView.length + target.length + (size == 0 ? 0 : target[0]);
}
@NAPI() Future<int> laterDefaults(int size) async {
  await Future<void>.delayed(const Duration(milliseconds: 1));
  return defaults(size);
}
@NAPI() int compute(int size) {
  final value = SharedBytes.allocate(size);
  if (size != 0) value[0] = 17;
  return size == 0 ? value.length : value[0];
}
@NAPI() Future<int> later(int size) async {
  await Future<void>.delayed(const Duration(milliseconds: 1));
  return compute(size);
}
@NAPI() class Internal {
  Internal(int size): value = compute(size);
  final int value;
}
''');
  await File('${project.path}/build.dart').writeAsString('''
import 'dart:io';
import 'package:napi/build.dart';
import 'package:napi/napi.dart';
Future<void> main() async {
  for (final external in [false, true]) {
    await buildPackage(
      library: File('business.dart').absolute.uri,
      output: Directory(external ? 'external' : 'package'),
      metadata: {'name': external ? '@napi/shared-bytes-external' : '@napi/shared-bytes-fixture', 'version': '0.0.0'},
      packagesPath: File('.dart_tool/package_config.json').absolute.path,
      external: external ? const ExternalLibrary([
        ExternalFunction('entries'),
        ExternalFunction('events'),
        ExternalFunction('remember'),
        ExternalFunction('same'),
        ExternalFunction('alive'),
        ExternalFunction('drop'),
        ExternalFunction('pressure'),
        ExternalFunction('allocate'),
        ExternalFunction('length'),
        ExternalFunction('read'),
        ExternalFunction('put'),
        ExternalFunction('view'),
        ExternalFunction('snapshot'),
        ExternalFunction('write'),
        ExternalFunction('copy'),
        ExternalFunction('nullable'),
        ExternalFunction('optional'),
        ExternalFunction('named'),
        ExternalFunction('requiredNamed'),
        ExternalFunction('lists'),
        ExternalFunction('maps'),
        ExternalFunction('dictionary'),
        ExternalFunction('record'),
        ExternalFunction('packet'),
        ExternalFunction('partial'),
        ExternalFunction('setConversion'),
        ExternalFunction('packets'),
        ExternalFunction('repairOutput'),
        ExternalClass('Repair', config: NAPI(classPolicy: ClassPolicy.value)),
        ExternalFunction('hold'),
        ExternalFunction('complete'),
        ExternalFunction('delayedRead'),
        ExternalFunction('caught'),
        ExternalFunction('fakeOutput'),
        ExternalFunction('fakeCopy'),
        ExternalClass('SharedBox'),
        ExternalClass('SharedPacket', config: NAPI(classPolicy: ClassPolicy.value)),
        ExternalClass('SharedOwner', config: NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')),
      ]) : null,
      ${native ? 'target: BuildTarget.native,\n      nativeRuntime: Directory(${jsonEncode(nativeRuntime.absolute.path)}),' : ''}
    );
  }
  await buildPackage(
    library: File('internal.dart').absolute.uri,
    output: Directory('internal'),
    metadata: {'name': '@napi/shared-bytes-internal', 'version': '0.0.0'},
    packagesPath: File('.dart_tool/package_config.json').absolute.path,
    ${native ? 'target: BuildTarget.native,\n    nativeRuntime: Directory(${jsonEncode(nativeRuntime.absolute.path)}),' : ''}
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
  final declaration = native ? 'module.d.mts' : 'module.d.wasm.ts';
  if (await File('${project.path}/package/$declaration').readAsString() !=
      await File('${project.path}/external/$declaration').readAsString()) {
    throw StateError(
      'Annotation and external shared_bytes declarations differ.',
    );
  }
  final archives = <String>[];
  for (final (directory, name) in [
    ('package', 'fixture'),
    ('external', 'external'),
    ('internal', 'internal'),
  ]) {
    final package = '${project.path}/$directory';
    await run('npm', ['pack', '--ignore-scripts', '--silent'], cwd: package);
    final archive = await File('$package/napi-shared-bytes-$name-0.0.0.tgz')
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
  await File('test/integration/shared_bytes.mjs')
      .copy('${consumer.path}/test.mjs');
  final declarations = await File('test/typescript/shared_bytes.mts')
      .readAsString();
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
