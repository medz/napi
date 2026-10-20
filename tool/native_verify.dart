import 'dart:convert';
import 'dart:io';

import 'package:napi/build.dart';
import 'package:napi/src/build/native_bundle.dart';
import 'package:napi/src/build/native_runtime.dart';

import 'verify.dart' show run, typescript;
import 'command.dart' show reportNodeVersions;
import 'value_fixture.dart';
import 'native_event_fixture.dart';
import 'native_host_value_fixture.dart';
import 'dual_target_fixture.dart';
import 'future_fixture.dart';
import 'void_fixture.dart';
import 'resource_fixture.dart';
import 'opaque_fixture.dart';
import 'stream_fixture.dart';
import 'cancellation_fixture.dart';
import 'binary_fixture.dart';
import 'concrete_fixture.dart';
import 'shared_bytes_fixture.dart';
import 'js_collections_fixture.dart';
import 'package_contents.dart';

/// Verify installed native consumers, with an optional offline runtime bundle.
Future<void> main(List<String> args) async {
  final packageOnly = args.isNotEmpty && args.first == '--packages-only';
  final paths = packageOnly ? args.skip(1).toList() : args;
  if (paths.length > 1 || paths.any((path) => path.startsWith('--'))) {
    throw ArgumentError(
      'Usage: dart run tool/native_verify.dart [runtime-bundle]\n'
      '   or: dart run tool/native_verify.dart --packages-only [runtime-bundle]',
    );
  }
  await reportNodeVersions();
  final supplied = paths.isEmpty ? null : Directory(paths.single).absolute;
  final temporary = await Directory.systemTemp.createTemp('napi native 中文 ');
  final root = Directory(temporary.resolveSymbolicLinksSync());
  stdout.writeln('Native verification artifacts: ${root.path}');
  // Preserve failed runs for diagnosis. Successful runs remove only this root.
  await verifyNativePackage(root, nativeRuntime: supplied);
  if (packageOnly) {
    await HttpOverrides.runWithHttpOverrides(
      () => verifyDualTargetFixture(root, supplied),
      _OfflineRuntime(),
    );
    await root.delete(recursive: true);
    return;
  }
  final bundle = (await resolveNativeRuntime(
    runtime: supplied,
    output: Directory('${root.path}/runtime-output'),
  )).directory;
  for (final kind in ['scalar', 'argument']) {
    final business = await Directory('${root.path}/$kind-business').create();
    final source = await File(
      'test/fixtures/${kind == 'scalar' ? 'scalar_exports' : 'arguments'}.dart',
    ).copy('${business.path}/business.dart');
    if (kind == 'scalar') {
      await File('test/fixtures/scalars.dart')
          .copy('${business.path}/scalars.dart');
    }
    final name = '@napi/native-$kind';
    final package = await buildPackage(
      library: source.uri,
      output: Directory('${business.path}/package'),
      metadata: {'name': name, 'version': '0.0.0'},
      packagesPath: File('.dart_tool/package_config.json').absolute.path,
      target: BuildTarget.native,
      nativeRuntime: bundle,
    );
    await run('npm', [
      'pack',
      '--ignore-scripts',
      '--silent',
    ], cwd: package.path);
    final archive = await File('${package.path}/napi-native-$kind-0.0.0.tgz')
        .copy('${root.path}/$kind.tgz');
    await business.delete(recursive: true);
    final consumer = await Directory('${root.path}/$kind').create();
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
    final contract = '${kind}_contract.mjs';
    await File('test/integration/$contract').copy('${consumer.path}/$contract');
    final verify = kind == 'scalar' ? 'verifyScalars' : 'verifyArguments';
    await File('${consumer.path}/test.mjs').writeAsString('''
import * as api from '$name';
import {$verify} from './$contract';
$verify(api);
console.log('Native $kind installed package: passed');
''');
    await run('node', ['test.mjs'], cwd: consumer.path);
    final declarations = await File(
      'test/typescript/${kind == 'scalar' ? 'scalars' : 'arguments'}.mts',
    ).readAsString();
    await File('${consumer.path}/consumer.mts')
        .writeAsString(declarations.replaceAll('./module.wasm', name));
    await typescript(consumer, 'consumer.mts');
  }
  await verifyValueOnlyFixture(root, nativeRuntime: bundle);
  await verifyNativeEvents(root, nativeRuntime: bundle);
  await verifyNativeHostValues(root, nativeRuntime: bundle);
  await verifyFutureFixture(root, nativeRuntime: bundle);
  await verifyVoidFixture(root, nativeRuntime: bundle);
  await verifyResourceFixture(root, nativeRuntime: bundle);
  await verifyOpaqueFixture(root, nativeRuntime: bundle);
  await verifyStreamFixture(root, nativeRuntime: bundle);
  await verifyCancellationFixture(root, nativeRuntime: bundle);
  await verifyBinaryFixture(root, nativeRuntime: bundle);
  await verifyConcreteFixture(root, nativeRuntime: bundle);
  await verifySharedBytesFixture(root, nativeRuntime: bundle);
  await verifyJsCollectionsFixture(root, nativeRuntime: bundle);
  await HttpOverrides.runWithHttpOverrides(
    () => verifyDualTargetFixture(root, supplied),
    _OfflineRuntime(),
  );
  final callbacks = await Process.run(
    Platform.resolvedExecutable,
    ['test', '-P', 'callback-native'],
    environment: {'NAPI_TEST_NATIVE_RUNTIME': bundle.path},
  );
  stdout.write(callbacks.stdout);
  stderr.write(callbacks.stderr);
  if (callbacks.exitCode != 0) {
    throw StateError('Native callback consumers exited ${callbacks.exitCode}');
  }
  await root.delete(recursive: true);
  stdout.writeln(
    'Generated native bindings, fresh npm install and TypeScript: passed',
  );
}

/// Build once, relocate the npm archive, and exercise its native API and types.
/// Omitting [nativeRuntime] exercises automatic runtime acquisition.
Future<void> verifyNativePackage(
  Directory root, {
  Directory? nativeRuntime,
}) async {
  // An independent Dart package invokes only the public build API.
  final project = await Directory('${root.path}/business').create();
  await File('${project.path}/pubspec.yaml').writeAsString('''
name: native_business_consumer
environment:
  sdk: ^3.13.5
dependencies:
  napi:
    path: ${jsonEncode(Directory.current.path)}
''');
  await File('test/fixtures/native_classes.dart')
      .copy('${project.path}/business.dart');
  await File('test/fixtures/value_classes.dart')
      .copy('${project.path}/value_classes.dart');
  await File('test/fixtures/dictionaries.dart')
      .copy('${project.path}/dictionaries.dart');
  await File('test/fixtures/maps.dart').copy('${project.path}/maps.dart');
  await File('test/fixtures/classes.dart').copy('${project.path}/classes.dart');
  await File('test/fixtures/reference_hierarchy.dart')
      .copy('${project.path}/reference_hierarchy.dart');
  await File('test/fixtures/reference_views.dart')
      .copy('${project.path}/reference_views.dart');
  await File('test/fixtures/named_list.dart')
      .copy('${project.path}/named_list.dart');
  await File('test/fixtures/structural_values.dart')
      .copy('${project.path}/structural_values.dart');
  await File('${project.path}/build.dart').writeAsString('''
import 'dart:io';
import 'package:napi/build.dart';
Future<void> main() async {
  await buildPackage(
    library: File('business.dart').absolute.uri,
    output: Directory('package'),
    metadata: {'name': '@napi/path', 'version': '0.0.0'},
    packagesPath: File('.dart_tool/package_config.json').absolute.path,
    target: BuildTarget.native,
    ${nativeRuntime == null ? '' : 'nativeRuntime: Directory(${jsonEncode(nativeRuntime.path)}),'}
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
  final package = Directory('${project.path}/package');
  final runtimeBundle = await NativeRuntimeBundle.read(package, built: true);
  final expectedFiles = {
    'package.json',
    'module.mjs',
    'module.d.mts',
    'module.aot',
    'runtime.json',
    ...runtimeBundle.hashes.keys,
  };
  final notices = {
    for (final name in ['DART_LICENSE', 'DART_AUTHORS', 'NAPI_LICENSE'])
      name: await File('${(nativeRuntime ?? package).path}/$name')
          .readAsBytes(),
  };
  final pack = await Process.run('npm', [
    'pack',
    '--ignore-scripts',
    '--json',
  ], workingDirectory: '${project.path}/package');
  if (pack.exitCode != 0) {
    throw StateError('npm pack failed: ${pack.stdout}${pack.stderr}');
  }
  final packed =
      (jsonDecode(pack.stdout as String) as List).single
          as Map<String, dynamic>;
  verifyPackedFiles(packed, expectedFiles);
  stdout.writeln('Native tarball files: ${jsonEncode(packed['files'])}');
  final archive = await File('${project.path}/package/${packed['filename']}')
      .copy('${root.path}/native.tgz');
  await project.delete(recursive: true);
  final consumer = await Directory('${root.path}/installed consumer 中文')
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
  await verifyInstalledPackage(
    Directory('${consumer.path}/node_modules/@napi/path'),
    expectedFiles,
    notices,
  );
  stdout.writeln(
    'Native installed file inventory and exact license notices: passed',
  );
  await File('test/integration/native_classes.mjs')
      .copy('${consumer.path}/test.mjs');
  await File('test/integration/class_contract.mjs')
      .copy('${consumer.path}/class_contract.mjs');
  await File('test/integration/structural_contract.mjs')
      .copy('${consumer.path}/structural_contract.mjs');
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
  await File('test/typescript/native_classes.mts')
      .copy('${consumer.path}/consumer.mts');
  await run('node', ['--expose-gc', 'test.mjs'], cwd: consumer.path);
  await typescript(consumer, 'consumer.mts');
  await File('${consumer.path}/shared_classes.mts').writeAsString(
    (await File('test/typescript/classes.mts').readAsString())
        .replaceAll('@napi/class-fixture/module.wasm', '@napi/path/native')
        .replaceAll('@napi/class-fixture', '@napi/path'),
  );
  await typescript(consumer, 'shared_classes.mts');
  await File('${consumer.path}/structures.mts').writeAsString(
    (await File(
      'test/typescript/structural_values.mts',
    ).readAsString()).replaceAll('./module.wasm', '@napi/path'),
  );
  await typescript(consumer, 'structures.mts');
  await File('${consumer.path}/maps.mts').writeAsString(
    (await File('test/typescript/maps.mts').readAsString())
        .replaceAll('@napi/class-fixture/module.wasm', '@napi/path/native')
        .replaceAll('@napi/class-fixture', '@napi/path'),
  );
  await typescript(consumer, 'maps.mts');
  await File('${consumer.path}/dictionaries.mts').writeAsString(
    (await File('test/typescript/dictionaries.mts').readAsString())
        .replaceAll('@napi/class-fixture/module.wasm', '@napi/path/native')
        .replaceAll('@napi/class-fixture', '@napi/path'),
  );
  await typescript(consumer, 'dictionaries.mts');
  await File('${consumer.path}/value_classes.mts').writeAsString(
    (await File('test/typescript/value_classes.mts').readAsString())
        .replaceAll('@napi/class-fixture/module.wasm', '@napi/path/native')
        .replaceAll('@napi/class-fixture', '@napi/path'),
  );
  await typescript(consumer, 'value_classes.mts');
  await File('${consumer.path}/reference_hierarchy.mts').writeAsString(
    (await File(
      'test/typescript/reference_hierarchy.mts',
    ).readAsString()).replaceAll('@napi/class-fixture', '@napi/path'),
  );
  await typescript(consumer, 'reference_hierarchy.mts');
  await File('${consumer.path}/reference_views.mts').writeAsString(
    (await File(
      'test/typescript/reference_views.mts',
    ).readAsString()).replaceAll('@napi/class-fixture', '@napi/path'),
  );
  await typescript(consumer, 'reference_views.mts');
  await File('${consumer.path}/workers-only.mjs').writeAsString('''
import {Worker} from 'node:worker_threads';
for (let i = 0; i < 4; i++) {
  await new Promise((resolve, reject) => {
    const worker = new Worker(new URL('./test.mjs', import.meta.url));
    worker.on('error', reject);
    worker.on('exit', code => code === 0 ? resolve() : reject(Error('Worker exit ' + code)));
  });
}
console.log('Native Worker-only unload and reload: passed');
''');
  await run('node', ['workers-only.mjs'], cwd: consumer.path);
}

final class _OfflineRuntime extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => throw StateError(
    'Dual packages must reuse the verified native runtime cache offline.',
  );
}
