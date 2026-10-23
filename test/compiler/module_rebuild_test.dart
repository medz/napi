import 'dart:io';

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

  group('managed modules', () {
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
