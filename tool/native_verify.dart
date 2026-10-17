import 'dart:convert';
import 'dart:io';

import 'package:napi/build.dart';
import 'package:napi/src/build/native_bundle.dart';

import 'verify.dart' show run, typescript;
import 'value_fixture.dart';
import 'native_event_fixture.dart';
import 'native_host_value_fixture.dart';
import 'future_fixture.dart';
import 'resource_fixture.dart';
import 'opaque_fixture.dart';
import 'callback_fixture.dart';
import 'stream_fixture.dart';
import 'cancellation_fixture.dart';
import 'binary_fixture.dart';
import 'concrete_fixture.dart';
import 'shared_bytes_fixture.dart';
import 'package_contents.dart';

/// Run explicitly with a maintainer-built runtime bundle. No native compiler,
/// SDK-source checkout, network access or package publication is used here.
Future<void> main(List<String> args) async {
  if (args.length != 1) {
    throw ArgumentError(
      'Usage: dart run tool/native_verify.dart <runtime-bundle>',
    );
  }
  final bundle = Directory(args.single).absolute;
  final runtimeBundle = await NativeRuntimeBundle.read(bundle);
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
      name: await File('${bundle.path}/$name').readAsBytes(),
  };
  final temporary = await Directory.systemTemp.createTemp('napi native 中文 ');
  final root = Directory(temporary.resolveSymbolicLinksSync());
  stdout.writeln('Native verification artifacts: ${root.path}');
  // Preserve failed runs for diagnosis. Successful runs remove only this root.
  for (final kind in ['scalar', 'argument']) {
    final module = await buildLibrary(
      library: File(
        'test/fixtures/${kind == 'scalar' ? 'scalar_exports' : 'arguments'}.dart',
      ).absolute.uri,
      output: Directory('${root.path}/$kind'),
      packagesPath: File('.dart_tool/package_config.json').absolute.path,
      target: BuildTarget.native,
      nativeRuntime: bundle,
    );
    final contract = '${kind}_contract.mjs';
    await File('test/integration/$contract')
        .copy('${module.directory.path}/$contract');
    final verify = kind == 'scalar' ? 'verifyScalars' : 'verifyArguments';
    await File('${module.directory.path}/test.mjs').writeAsString('''
import * as api from './module.mjs';
import {$verify} from './$contract';
$verify(api);
console.log('Native $kind shared contract: passed');
''');
    await run('node', ['test.mjs'], cwd: module.directory.path);
    final consumer = await File(
      'test/typescript/${kind == 'scalar' ? 'scalars' : 'arguments'}.mts',
    ).readAsString();
    await File('${module.directory.path}/consumer.mts')
        .writeAsString(consumer.replaceAll('./module.wasm', './module.mjs'));
    await typescript(module.directory, 'consumer.mts');
  }
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
    nativeRuntime: Directory(${jsonEncode(bundle.path)}),
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
  await verifyValueOnlyFixture(root, nativeRuntime: bundle);
  await verifyNativeEvents(root, nativeRuntime: bundle);
  await verifyNativeHostValues(root, nativeRuntime: bundle);
  await verifyFutureFixture(root, nativeRuntime: bundle);
  await verifyResourceFixture(root, nativeRuntime: bundle);
  await verifyOpaqueFixture(root, nativeRuntime: bundle);
  await verifyCallbackFixture(root, nativeRuntime: bundle);
  await verifyStreamFixture(root, nativeRuntime: bundle);
  await verifyCancellationFixture(root, nativeRuntime: bundle);
  await verifyBinaryFixture(root, nativeRuntime: bundle);
  await verifyConcreteFixture(root, nativeRuntime: bundle);
  await verifySharedBytesFixture(root, nativeRuntime: bundle);
  await root.delete(recursive: true);
  stdout.writeln(
    'Generated native bindings, fresh npm install and TypeScript: passed',
  );
}
