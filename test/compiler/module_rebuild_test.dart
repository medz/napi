import 'dart:io';
import 'dart:ffi' show Abi;

import 'package:napi/src/build/build.dart';
import 'package:napi/src/build/output_ownership.dart';
import 'package:napi/src/build/publish.dart';
import 'package:napi/src/compiler/sdk_adapter/dart_sdk_adapter.dart';
import 'package:test/test.dart';

void main() {
  String? unsupported;
  try {
    checkPackageRebuildFilesystem(Directory.systemTemp);
  } on UnsupportedError catch (error) {
    unsupported = error.toString();
  }
  late Directory root;
  late Directory output;
  late File source;
  setUp(() async {
    root = await Directory(await Directory.systemTemp.resolveSymbolicLinks())
        .createTemp('napi module rebuild ');
    output = await Directory('${root.path}/output').create();
    source = await File('${root.path}/business.dart').writeAsString('''
import 'package:napi/napi.dart';
@NAPI() int add(int value) => value + 1;
''');
    for (final name in wasmPackageFiles) {
      await File('${output.path}/$name').writeAsString('old $name');
    }
    await writeOutputOwnership(
      output,
      kind: OutputKind.module,
      targets: {'wasm'},
      root: 'wasm',
      runtime: null,
      calls: false,
    );
  });
  tearDown(() => root.delete(recursive: true));

  Future<BuiltModule> rebuild() => buildLibrary(
    library: source.uri,
    output: output,
    packagesPath: File('.dart_tool/package_config.json').absolute.path,
    sdk: DartSdkAdapter(executable: '${root.path}/missing-dart'),
  );

  test('unsupported rebuild leaves the existing module intact', () async {
    await expectLater(rebuild(), throwsUnsupportedError);
    expect(
      await File('${output.path}/module.wasm').readAsString(),
      'old module.wasm',
    );
  }, skip: unsupported == null);

  for (final target in BuildTarget.values) {
    test('fresh $target modules cannot occupy lock paths', () async {
      for (final name in ['.napi-locks', '.NAPI-LOCKS', '.napi-locks/module']) {
        await expectLater(
          buildLibrary(
            library: source.uri,
            output: Directory('${root.path}/$name'),
            packagesPath: File('.dart_tool/package_config.json').absolute.path,
            sdk: DartSdkAdapter(executable: '${root.path}/missing-dart'),
            target: target,
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(await Directory('${root.path}/$name').exists(), isFalse);
      }
    });
  }

  group('managed modules', () {
    test('implicit native cache cannot write into the live module', () async {
      final cache = Directory('${output.path}/cache');
      final marker = await File('${output.path}/$outputOwnershipFile')
          .readAsString();
      final script = await File('${root.path}/rebuild.dart').writeAsString('''
import 'dart:io';
import 'package:napi/build.dart';
class Offline extends HttpOverrides {
  HttpClient createHttpClient(SecurityContext? context) =>
      throw StateError('The cache must be rejected before downloading.');
}
Future<void> main(List<String> args) async {
  try {
    await HttpOverrides.runWithHttpOverrides(() => buildLibrary(
      library: File(args[0]).uri,
      output: Directory(args[1]),
      packagesPath: args[2],
      target: BuildTarget.native,
    ), Offline());
  } on ArgumentError {
    return;
  }
  throw StateError('The overlapping cache was accepted.');
}
''');
      final packages = File('.dart_tool/package_config.json').absolute.path;
      final result = await Process.run(
        Platform.resolvedExecutable,
        [
          '--packages=$packages',
          script.path,
          source.path,
          output.path,
          packages,
        ],
        environment: {'NAPI_RUNTIME_CACHE': cache.path},
      );
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(await cache.exists(), isFalse);
      expect(
        await File('${output.path}/module.wasm').readAsString(),
        'old module.wasm',
      );
      expect(
        await File('${output.path}/$outputOwnershipFile').readAsString(),
        marker,
      );
    }, skip: !Platform.isMacOS || Abi.current() != Abi.macosArm64);

    test(
      'compiler startup failure preserves artifacts and author content',
      () async {
        final author = await File('${output.path}/notes.txt')
            .writeAsString('keep');
        final marker = await File('${output.path}/$outputOwnershipFile')
            .readAsString();
        await expectLater(rebuild(), throwsA(isA<ProcessException>()));
        expect(await author.readAsString(), 'keep');
        expect(
          await File('${output.path}/module.wasm').readAsString(),
          'old module.wasm',
        );
        expect(
          await File('${output.path}/$outputOwnershipFile').readAsString(),
          marker,
        );
        expect(
          await root
              .list()
              .where((file) => file.path.contains('.napi-module-rebuild-'))
              .isEmpty,
          isTrue,
        );
      },
    );

    test(
      'modified generated files fail before starting the compiler',
      () async {
        await File('${output.path}/module.wasm').writeAsString('user edit');
        await expectLater(rebuild(), throwsArgumentError);
        expect(
          await File('${output.path}/module.wasm').readAsString(),
          'user edit',
        );
      },
    );

    test('unowned output is not adopted', () async {
      await File('${output.path}/$outputOwnershipFile').delete();
      await expectLater(rebuild(), throwsArgumentError);
      expect(
        await File('${output.path}/module.wasm').readAsString(),
        'old module.wasm',
      );
    });

    test('package ownership cannot authorize a module rebuild', () async {
      await writeOutputOwnership(
        output,
        kind: OutputKind.package,
        targets: {'wasm'},
        root: 'wasm',
        runtime: null,
        calls: false,
      );
      await expectLater(rebuild(), throwsFormatException);
      expect(
        await File('${output.path}/module.wasm').readAsString(),
        'old module.wasm',
      );
    });
  }, skip: unsupported);
}
