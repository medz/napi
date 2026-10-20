import 'dart:convert';
import 'dart:io';

import 'package:napi/build.dart';
import 'package:napi/src/build/native_bundle.dart';
import 'package:napi/src/compiler/sdk_adapter/dart_sdk_adapter.dart';

import 'command.dart';
import 'package_contents.dart';

/// One tarball contains both targets; every selected Node consumes the same bits.
Future<void> verifyDualTargetFixture(
  Directory root, [
  Directory? runtime,
]) async {
  final directory = await Directory(await root.resolveSymbolicLinks())
      .createTemp('dual target 雪 ');
  await _verifyFailureCleanup(directory, runtime);
  final source = await File('test/fixtures/dual_target.dart')
      .copy('${directory.path}/business.dart');
  Set<String>? expected;
  Map<String, List<int>>? notices;
  final archives = <String>[];
  String? declarations;
  for (final external in [false, true]) {
    final name = external ? 'external' : 'fixture';
    final package = await buildPackage(
      library: source.uri,
      output: Directory('${directory.path}/$name'),
      metadata: {
        'name': '@napi/dual-$name',
        'version': '0.0.0',
        'author': {'name': 'Dual Fixture'},
        'license': 'MIT',
      },
      assets: {'LICENSE': File('LICENSE')},
      packagesPath: File('.dart_tool/package_config.json').absolute.path,
      external: external
          ? ExternalLibrary([
              for (final name in [
                'calls',
                'cleanups',
                'reset',
                'add',
                'format',
                'identity',
                'singleton',
                'invoke',
                'later',
                'sequence',
                'fail',
                'structuralDefaults',
                'namedDefaults',
                'appendRow',
                'objectDefaults',
                'objectDefaultToken',
                'objectDefaultAfter',
                'namedObjectDefault',
                'objectDefaultValue',
                'valueFieldDefault',
                'genericObjectDefault',
                'factoryObjectDefault',
                'resourceDefault',
                'namedResourceDefault',
                'resourceDefaultLater',
                'resourceDefaultSequence',
                'resourceDefaultSignal',
                'resourceDefaultChecked',
                'originPointDefault',
                'staticObjectDefault',
                'namedContainerDefaults',
                'namedValueFieldDefault',
                'originResourceDefault',
                'namedResourceUse',
              ])
                ExternalFunction(name),
              ExternalClass('Counter'),
              ExternalClass('DefaultBase'),
              ExternalClass('DefaultChild'),
              ExternalClass('DefaultToken'),
              ExternalClass('DefaultIntBox'),
              ExternalClass('DefaultProjection'),
              ExternalClass('NamedPoint'),
              ExternalClass(
                'NamedValue',
                config: const NAPI(
                  classPolicy: ClassPolicy.value,
                  valueConstructor: 'new',
                ),
              ),
              ExternalClass(
                'ReferenceFieldValue',
                config: const NAPI(
                  classPolicy: ClassPolicy.value,
                  valueConstructor: 'new',
                ),
              ),
              ExternalClass(
                'DefaultValue',
                config: const NAPI(
                  classPolicy: ClassPolicy.value,
                  valueConstructor: 'new',
                ),
              ),
              ExternalClass(
                'Resource',
                config: const NAPI(
                  classPolicy: ClassPolicy.resource,
                  cleanup: 'close',
                ),
              ),
              ExternalClass(
                'ConstResource',
                config: const NAPI(
                  classPolicy: ClassPolicy.resource,
                  cleanup: 'close',
                ),
              ),
              ExternalClass(
                'NamedResource',
                config: const NAPI(
                  classPolicy: ClassPolicy.resource,
                  cleanup: 'close',
                ),
              ),
            ])
          : null,
      targets: {BuildTarget.wasm, BuildTarget.native},
      target: external ? BuildTarget.native : BuildTarget.wasm,
      nativeRuntime: runtime,
    );
    final native = Directory('${package.path}/native');
    final bundle = await NativeRuntimeBundle.read(native, built: true);
    expected ??= {
      'package.json',
      'LICENSE',
      for (final name in [
        'module.wasm',
        'module.d.wasm.ts',
        'host.mjs',
        'boundary.mjs',
        'core.wasm',
        'calls.mjs',
        'references.mjs',
        'DART_LICENSE',
      ])
        'wasm/$name',
      for (final name in [
        'module.mjs',
        'module.d.mts',
        'module.aot',
        'runtime.json',
        ...bundle.hashes.keys,
      ])
        'native/$name',
    };
    notices ??= <String, List<int>>{
      'LICENSE': await File('LICENSE').readAsBytes(),
      'wasm/DART_LICENSE': await File(
        '${File(Platform.resolvedExecutable).parent.parent.path}/LICENSE',
      ).readAsBytes(),
      for (final name in ['DART_LICENSE', 'DART_AUTHORS', 'NAPI_LICENSE'])
        'native/$name': await File('${(runtime ?? native).path}/$name')
            .readAsBytes(),
    };
    final manifest = jsonDecode(
      await File('${package.path}/package.json').readAsString(),
    ) as Map;
    if (manifest.containsKey('os') ||
        manifest.containsKey('cpu') ||
        jsonEncode(manifest['author']) != '{"name":"Dual Fixture"}') {
      throw StateError('Dual root metadata was restricted or lost.');
    }
    final types = await File('${package.path}/native/module.d.mts')
        .readAsString();
    if (types !=
            await File('${package.path}/wasm/module.d.wasm.ts')
                .readAsString() ||
        (declarations != null && declarations != types)) {
      throw StateError('Target/selector declarations differ.');
    }
    declarations = types;
    for (final text in [
      'export type Row = ',
      'A labeled row of copied numbers.',
      'Appends a number to the copied row without changing the JavaScript input.',
    ]) {
      if (!types.contains(text)) {
        throw StateError('Missing public type or Dartdoc: $text');
      }
    }
    final pack = await Process.run('npm', [
      'pack',
      '--ignore-scripts',
      '--json',
      '--cache',
      '${directory.path}/npm cache',
    ], workingDirectory: package.path);
    if (pack.exitCode != 0) throw StateError('${pack.stdout}${pack.stderr}');
    final packed =
        (jsonDecode(pack.stdout as String) as List).single
            as Map<String, dynamic>;
    verifyPackedFiles(packed, expected);
    stdout.writeln('Dual $name packed: ${jsonEncode(packed)}');
    final archive = await File('${package.path}/${packed['filename']}')
        .copy('${directory.path}/$name.tgz');
    archives.add(archive.path);
    await package.delete(recursive: true);
  }
  await source.delete();
  final consumer = await Directory('${directory.path}/installed consumer 雪')
      .create();
  await File('${consumer.path}/package.json')
      .writeAsString('{"private":true,"type":"module"}');
  await run('npm', [
    'install',
    '--offline',
    '--ignore-scripts',
    '--no-audit',
    '--no-fund',
    '--cache',
    '${directory.path}/npm cache',
    ...archives,
  ], cwd: consumer.path);
  for (final name in ['fixture', 'external']) {
    await verifyInstalledPackage(
      Directory('${consumer.path}/node_modules/@napi/dual-$name'),
      expected!,
      notices!,
      recursive: true,
    );
  }
  await File('test/integration/dual_target.mjs')
      .copy('${consumer.path}/test.mjs');
  await File('test/typescript/dual_target.mts')
      .copy('${consumer.path}/consumer.mts');
  await run('node', ['--expose-gc', 'test.mjs'], cwd: consumer.path);
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
          '--noEmit',
          '--target',
          'ES2022',
          '--module',
          mode == 'NodeNext' ? 'NodeNext' : 'ESNext',
          '--moduleResolution',
          mode,
          '--allowArbitraryExtensions',
          '--exactOptionalPropertyTypes',
          exact,
          '--noUncheckedIndexedAccess',
          unchecked,
          'consumer.mts',
        ], cwd: consumer.path);
      }
    }
  }
  stdout.writeln('Dual target fresh packages and TypeScript: passed');
  stdout.writeln('Consumer: ${consumer.path}');
}

Future<void> _verifyFailureCleanup(Directory root, Directory? runtime) async {
  final source = await Directory('${root.path}/failure sources').create();
  final entry = File('${source.path}/entry.dart');
  await entry.writeAsString(
    "export 'wasm.dart' if (dart.library.ffi) 'native.dart';",
  );
  await File('${source.path}/wasm.dart').writeAsString('''
import 'package:napi/napi.dart';
@NAPI() int run([int value = 1]) => value;
''');
  final native = File('${source.path}/native.dart');
  await native.writeAsString('''
import 'package:napi/napi.dart';
@NAPI() int run([int value = 2]) => value;
''');
  final output = Directory('${root.path}/failed output/package');
  Future<Directory> build() => buildPackage(
    library: entry.uri,
    output: output,
    metadata: {'name': '@napi/failed-dual', 'version': '0.0.0'},
    packagesPath: File('.dart_tool/package_config.json').absolute.path,
    targets: {BuildTarget.wasm, BuildTarget.native},
    nativeRuntime: runtime,
  );
  var rejected = false;
  try {
    await build();
  } on BindingDiagnostic catch (error) {
    if (error.code != 'NAPI_PACKAGE_CONTRACT') rethrow;
    rejected = true;
  }
  if (!rejected || await output.parent.exists()) {
    throw StateError('A contract mismatch must fail before creating staging.');
  }
  // Valid VM analysis but unsupported by AOT. The first (Wasm) build succeeds;
  // the second compilation must fail without publishing either module.
  await native.writeAsString('''
import 'dart:mirrors';
import 'package:napi/napi.dart';
@NAPI() int run([int value = 1]) => reflect(value).reflectee as int;
''');
  await output.parent.create();
  final sentinel = File('${output.parent.path}/keep.txt');
  await sentinel.writeAsString('unrelated author file');
  rejected = false;
  try {
    await build();
  } on SdkCompatibilityException catch (error) {
    if (error.code != 'NAPI_DART_COMPILATION' ||
        !error.message.contains('Dart AOT compilation failed')) {
      rethrow;
    }
    rejected = true;
  }
  if (!rejected ||
      await output.exists() ||
      await output.parent.list().length != (Platform.isWindows ? 1 : 2) ||
      await sentinel.readAsString() != 'unrelated author file') {
    throw StateError(
      'Failed second target must preserve author files and its stable lock.',
    );
  }
  stdout.writeln(
    'Dual contract preflight and second-target failure cleanup: passed',
  );
}

Future<void> main(List<String> args) async {
  if (args.length > 1) {
    throw ArgumentError(
      'Usage: dart run tool/dual_target_fixture.dart [native-runtime-bundle]',
    );
  }
  await reportNodeVersions();
  final root = await Directory('.dart_tool').createTemp('napi dual ');
  await verifyDualTargetFixture(
    root,
    args.isEmpty ? null : Directory(args.single).absolute,
  );
}
