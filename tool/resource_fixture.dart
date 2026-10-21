import 'dart:convert';
import 'dart:io';

import 'verify.dart' show run, typescript;

/// Runs the same resource contract against independently packed backend modules.
Future<void> verifyResourceFixture(
  Directory root, {
  Directory? nativeRuntime,
}) async {
  final native = nativeRuntime != null;
  final backend = native ? 'native' : 'wasm';
  final canonical = await Directory(root.resolveSymbolicLinksSync())
      .createTemp('resources $backend 雪 ');
  final project = await Directory('${canonical.path}/business 中文').create();
  await File('${project.path}/pubspec.yaml').writeAsString('''
name: resources_business
environment:
  sdk: ^3.13.5
dependencies:
  napi:
    path: ${jsonEncode(Directory.current.path)}
''');
  await File('test/fixtures/resources.dart')
      .copy('${project.path}/business.dart');
  await File('${project.path}/build.dart').writeAsString('''
import 'dart:io';
import 'package:napi/build.dart';
Future<void> main() async {
  for (final external in [false, true]) {
    await buildPackage(
    library: File('business.dart').absolute.uri,
    output: Directory(external ? 'external' : 'package'),
    metadata: {'name': external ? '@napi/resources-external' : '@napi/resources-fixture', 'version': '0.0.0'},
    packagesPath: File('.dart_tool/package_config.json').absolute.path,
    external: external ? const ExternalLibrary([
      ExternalClass('ValueDefaultResource', config: NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')),
      ExternalClass('ResourceDefaultValue', config: NAPI(classPolicy: ClassPolicy.value)),
      ExternalClass('GenericResource', config: NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')),
      ExternalFunction('resourceDefaultEcho'),
      ExternalFunction('resourceDefaultHold'),
      ExternalFunction('resourceEvents'),
      ExternalFunction('resourceCleanupCalls'),
      ExternalFunction('resourceCleanupCode'),
      ExternalFunction('resourceComplete'),
    ]) : null,
    ${native ? 'target: BuildTarget.native,\n    nativeRuntime: Directory(${jsonEncode(nativeRuntime.absolute.path)}),' : ''}
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
  for (final name in ['fixture', 'external']) {
    final directory = '${project.path}/${name == 'fixture' ? 'package' : name}';
    await run('npm', ['pack', '--ignore-scripts', '--silent'], cwd: directory);
    final archive = await File('$directory/napi-resources-$name-0.0.0.tgz')
        .copy('${canonical.path}/$name.tgz');
    archives.add(archive.path);
  }
  // Only the packed installation remains available to the consumer.
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
  await File('test/integration/resources.mjs')
      .copy('${consumer.path}/test.mjs');
  final declarations = await File('test/typescript/resources.mts')
      .readAsString();
  await File('${consumer.path}/consumer.mts').writeAsString(
    declarations.replaceAll('/BACKEND', native ? '/native' : '/module.wasm'),
  );
  await run('node', ['--expose-gc', 'test.mjs'], cwd: consumer.path);
  await typescript(consumer, 'consumer.mts');
  stdout.writeln('Resource $backend fresh package and TypeScript: passed');
}

Future<void> main(List<String> args) async {
  if (args.length > 1) {
    throw ArgumentError(
      'Usage: dart run tool/resource_fixture.dart [native-runtime-bundle]',
    );
  }
  final root = await Directory('.dart_tool').createTemp('napi resources ');
  stdout.writeln('Resource verification artifacts: ${root.absolute.path}');
  await verifyResourceFixture(
    root,
    nativeRuntime: args.isEmpty ? null : Directory(args.single),
  );
}
