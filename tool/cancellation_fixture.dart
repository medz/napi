import 'dart:convert';
import 'dart:io';

import 'verify.dart' show run;

/// Verifies generated cancellation declarations in relocated, installed packages.
Future<void> verifyCancellationFixture(
  Directory root, {
  Directory? nativeRuntime,
}) async {
  final native = nativeRuntime != null;
  final backend = native ? 'native' : 'wasm';
  final canonical = await Directory(root.resolveSymbolicLinksSync())
      .createTemp('cancellation $backend 雪 ');
  final project = await Directory('${canonical.path}/business 中文').create();
  await File('${project.path}/pubspec.yaml').writeAsString('''
name: cancellation_business
environment:
  sdk: ^3.13.5
dependencies:
  napi:
    path: ${jsonEncode(Directory.current.path)}
''');
  await File('test/fixtures/cancellation.dart')
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
      metadata: {'name': external ? '@napi/cancellation-external' : '@napi/cancellation-fixture', 'version': '0.0.0'},
      packagesPath: File('.dart_tool/package_config.json').absolute.path,
      external: external ? const ExternalLibrary([
        ExternalFunction('entries'),
        ExternalFunction('events'),
        ExternalFunction('check'),
        ExternalFunction('peekAfter'),
        ExternalFunction('checkAfter'),
        ExternalFunction('guarded'),
        ExternalFunction('setConversion'),
        ExternalFunction('immediate'),
        ExternalFunction('optional'),
        ExternalFunction('named'),
        ExternalFunction('resolved'),
        ExternalFunction('completeWork'),
        ExternalFunction('work'),
        ExternalFunction('timerWork'),
        ExternalFunction('remember'),
        ExternalFunction('tokenAlive'),
        ExternalFunction('removeRetained'),
        ExternalFunction('pressure'),
        ExternalFunction('cancelComplete'),
        ExternalFunction('once'),
        ExternalClass('WorkOwner', config: NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')),
        ExternalClass('CleanupSignal', config: NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')),
        ExternalClass('SavedSignal'),
        ExternalClass('GuardValue', config: NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new')),
        ExternalClass('SignalFeed', config: NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')),
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
    final archive = await File('$package/napi-cancellation-$name-0.0.0.tgz')
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
  await File('test/integration/cancellation.mjs')
      .copy('${consumer.path}/test.mjs');
  final declarations = await File('test/typescript/cancellation.mts')
      .readAsString();
  await run('node', ['--expose-gc', 'test.mjs'], cwd: consumer.path);
  final tsc =
      Platform.environment['NAPI_TSC'] ??
      '${Directory.current.path}/.dart_tool/js/node_modules/typescript/bin/tsc';
  for (final mode in ['NodeNext', 'Bundler']) {
    for (final exact in ['true', 'false']) {
      await File('${consumer.path}/consumer.mts').writeAsString(
        declarations.replaceAll(
          '/BACKEND',
          native ? '/native' : '/module.wasm',
        ),
      );
      for (final strictFunctions in ['true', 'false']) {
        await run('node', [
          File(tsc).absolute.path,
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
  stdout.writeln('Cancellation $backend fresh packages and TypeScript: passed');
}

Future<void> main(List<String> args) async {
  if (args.length > 1) {
    throw ArgumentError(
      'Usage: dart run tool/cancellation_fixture.dart [native-runtime-bundle]',
    );
  }
  final root = await Directory('.dart_tool').createTemp('napi cancellation ');
  stdout.writeln('Cancellation verification artifacts: ${root.absolute.path}');
  await verifyCancellationFixture(
    root,
    nativeRuntime: args.isEmpty ? null : Directory(args.single),
  );
}
