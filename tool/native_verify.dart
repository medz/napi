import 'dart:convert';
import 'dart:io';

import 'package:napi/build.dart';

import 'verify.dart' show run, typescript;

/// Run explicitly with a maintainer-built runtime bundle. No native compiler,
/// SDK-source checkout, network access or package publication is used here.
Future<void> main(List<String> args) async {
  if (args.length != 1) {
    throw ArgumentError(
      'Usage: dart run tool/native_verify.dart <runtime-bundle>',
    );
  }
  final bundle = Directory(args.single).absolute;
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
  await File('test/fixtures/dictionaries.dart')
      .copy('${project.path}/dictionaries.dart');
  await File('test/fixtures/maps.dart').copy('${project.path}/maps.dart');
  await File('test/fixtures/classes.dart').copy('${project.path}/classes.dart');
  await File('test/fixtures/named_list.dart')
      .copy('${project.path}/named_list.dart');
  await File('test/fixtures/structural_values.dart')
      .copy('${project.path}/structural_values.dart');
  await File('${project.path}/build.dart').writeAsString('''
import 'dart:io';
import 'package:napi/build.dart';
Future<void> main() async {
  final built = await buildLibrary(
    library: File('business.dart').absolute.uri,
    output: Directory('built'),
    packagesPath: File('.dart_tool/package_config.json').absolute.path,
    target: BuildTarget.native,
    nativeRuntime: Directory(${jsonEncode(bundle.path)}),
  );
  await assembleNativePackage(module: built, output: Directory('package'),
    metadata: {'name': '@napi/native-fixture', 'version': '0.0.0'});
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
    '${project.path}/package/napi-native-fixture-0.0.0.tgz',
  ).copy('${root.path}/native.tgz');
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
  await File('test/integration/native_classes.mjs')
      .copy('${consumer.path}/test.mjs');
  await File('test/integration/class_contract.mjs')
      .copy('${consumer.path}/class_contract.mjs');
  await File('test/integration/structural_contract.mjs')
      .copy('${consumer.path}/structural_contract.mjs');
  await File('test/integration/reference_contract.mjs')
      .copy('${consumer.path}/reference_contract.mjs');
  await File('test/integration/structural_reference_contract.mjs')
      .copy('${consumer.path}/structural_reference_contract.mjs');
  await File('test/integration/map_contract.mjs')
      .copy('${consumer.path}/map_contract.mjs');
  await File('test/integration/dictionary_contract.mjs')
      .copy('${consumer.path}/dictionary_contract.mjs');
  await File('test/typescript/native_classes.mts')
      .copy('${consumer.path}/consumer.mts');
  await run('node', ['--expose-gc', 'test.mjs'], cwd: consumer.path);
  await typescript(consumer, 'consumer.mts');
  await File('${consumer.path}/shared_classes.mts').writeAsString(
    (await File('test/typescript/classes.mts').readAsString())
        .replaceAll(
          '@napi/class-fixture/module.wasm',
          '@napi/native-fixture/native',
        )
        .replaceAll('@napi/class-fixture', '@napi/native-fixture'),
  );
  await typescript(consumer, 'shared_classes.mts');
  await File('${consumer.path}/structures.mts').writeAsString(
    (await File(
      'test/typescript/structural_values.mts',
    ).readAsString()).replaceAll('./module.wasm', '@napi/native-fixture'),
  );
  await typescript(consumer, 'structures.mts');
  await File('${consumer.path}/maps.mts').writeAsString(
    (await File('test/typescript/maps.mts').readAsString())
        .replaceAll(
          '@napi/class-fixture/module.wasm',
          '@napi/native-fixture/native',
        )
        .replaceAll('@napi/class-fixture', '@napi/native-fixture'),
  );
  await typescript(consumer, 'maps.mts');
  await File('${consumer.path}/dictionaries.mts').writeAsString(
    (await File('test/typescript/dictionaries.mts').readAsString())
        .replaceAll(
          '@napi/class-fixture/module.wasm',
          '@napi/native-fixture/native',
        )
        .replaceAll('@napi/class-fixture', '@napi/native-fixture'),
  );
  await typescript(consumer, 'dictionaries.mts');
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
  await root.delete(recursive: true);
  stdout.writeln(
    'Generated native bindings, fresh npm install and TypeScript: passed',
  );
}
