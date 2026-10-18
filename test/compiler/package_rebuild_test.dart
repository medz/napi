import 'dart:convert';
import 'dart:io';

import 'package:napi/build.dart';
import 'package:napi/src/build/package_ownership.dart';
import 'package:napi/src/build/publish.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Directory source;
  late Directory output;
  const metadata = {'name': '@fixture/rebuild', 'version': '1.0.0'};

  setUp(() async {
    root = await Directory(await Directory.systemTemp.resolveSymbolicLinks())
        .createTemp('napi package rebuild ');
    source = await Directory('${root.path}/module').create();
    output = Directory('${root.path}/package');
    for (final name in wasmPackageFiles) {
      await File('${source.path}/$name').writeAsString('first $name');
    }
  });
  tearDown(() => root.delete(recursive: true));

  Future<Directory> assemble({
    Map<String, Object?> overrides = const {},
    Map<String, File> assets = const {},
  }) => assembleWasmPackage(
    module: BuiltModule(source, '3.13.5'),
    output: output,
    metadata: {...metadata, ...overrides},
    assets: assets,
  );
  Future<Map<String, dynamic>> package() async =>
      jsonDecode(await File('${output.path}/package.json').readAsString())
          as Map<String, dynamic>;
  Future<void> editPackage(void Function(Map<String, dynamic>) edit) async {
    final value = await package();
    edit(value);
    await File('${output.path}/package.json').writeAsString(jsonEncode(value));
  }

  test(
    'fresh packages carry private ownership outside the npm file list',
    () async {
      await assemble();
      expect(
        await File('${output.path}/$packageOwnershipFile').exists(),
        isTrue,
      );
      expect((await package())['files'], isNot(contains(packageOwnershipFile)));
      expect(await PackageOwnership.read(output), isA<PackageOwnership>());
    },
  );

  test(
    'unsupported hosts retain managed output without attempting replacement',
    () async {
      await assemble();
      await File('${source.path}/module.wasm').writeAsString('second');
      await expectLater(assemble(), throwsUnsupportedError);
      expect(
        await File('${output.path}/module.wasm').readAsString(),
        'first module.wasm',
      );
    },
    skip: Platform.isMacOS,
  );

  test(
    'external package URI reaches frontend diagnostics without a file-URI cast',
    () async {
      await expectLater(
        buildPackage(
          library: Uri.parse('package:napi/napi.dart'),
          output: output,
          metadata: metadata,
          external: ExternalLibrary([ExternalFunction('missingSelectedName')]),
        ),
        throwsA(isA<BindingDiagnostic>()),
      );
      expect(await output.parent.list().length, 1);
    },
  );

  group('managed macOS replacement', () {
    test(
      'a legal 255-byte basename supports fresh publication and rebuilding',
      () async {
        output = Directory('${root.path}/${'x' * 255}');
        await assemble();
        await File('${source.path}/module.wasm').writeAsString('second');
        await assemble(overrides: {'version': '1.0.1'});
        expect(
          await File('${output.path}/module.wasm').readAsString(),
          'second',
        );
        expect((await package())['version'], '1.0.1');
        expect(
          await File('${root.path}/.napi-locks/${'x' * 255}').exists(),
          isTrue,
        );
      },
    );
    test(
      'author JSON larger than the private marker limit remains rebuildable',
      () async {
        final text = 'x' * (1024 * 1024 + 1);
        await assemble(overrides: {'largeAuthorField': text});
        await assemble(overrides: {'version': '1.0.1'});
        expect((await package())['largeAuthorField'], text);
        final marker = File('${output.path}/$packageOwnershipFile');
        await marker.writeAsString(' ' * (1024 * 1024 + 1));
        await expectLater(assemble(), throwsFormatException);
        expect((await package())['largeAuthorField'], text);
      },
    );
    test(
      'preserves author content, omitted assets and top-level JSON overrides',
      () async {
        final license = await File('${root.path}/license')
            .writeAsString('license one');
        await assemble(
          overrides: {
            'author': {'name': 'Author'},
            'custom': {'old': 1},
          },
          assets: {'LICENSE': license},
        );
        await Directory('${output.path}/author/empty').create(recursive: true);
        await File('${output.path}/author/notes.txt').writeAsString('keep');
        await File('${output.path}/LICENSE')
            .writeAsString('author edited license');
        await editPackage((value) {
          value['futureMetadata'] = [
            1,
            null,
            {'x': true},
          ];
        });
        await File('${source.path}/module.wasm').writeAsString('second');
        await assemble(overrides: {'version': '1.0.1', 'custom': null});
        final result = await package();
        expect(result['version'], '1.0.1');
        expect(result['author'], {'name': 'Author'});
        expect(result.containsKey('custom'), isTrue);
        expect(result['custom'], isNull);
        expect(result['futureMetadata'], [
          1,
          null,
          {'x': true},
        ]);
        expect(result['files'], contains('LICENSE'));
        expect(result['files'], isNot(contains('author/notes.txt')));
        expect(
          await File('${output.path}/author/notes.txt').readAsString(),
          'keep',
        );
        expect(await Directory('${output.path}/author/empty').exists(), isTrue);
        expect(
          await File('${output.path}/LICENSE').readAsString(),
          'author edited license',
        );
        expect(
          await File('${output.path}/module.wasm').readAsString(),
          'second',
        );
        await license.writeAsString('explicit replacement');
        await assemble(assets: {'LICENSE': license});
        expect(
          await File('${output.path}/LICENSE').readAsString(),
          'explicit replacement',
        );
      },
    );

    test('removes only stale generated callable files', () async {
      for (final name in wasmCallFiles) {
        await File('${source.path}/$name').writeAsString(name);
      }
      await assemble();
      await File('${output.path}/unrelated.txt').writeAsString('keep');
      for (final name in wasmCallFiles) {
        await File('${source.path}/$name').delete();
      }
      await assemble();
      for (final name in wasmCallFiles) {
        expect(await File('${output.path}/$name').exists(), isFalse);
      }
      expect(await File('${output.path}/unrelated.txt').readAsString(), 'keep');
    });

    test(
      'generated-file conflicts leave the old generation unchanged',
      () async {
        await assemble();
        await File('${output.path}/module.wasm').writeAsString('author edit');
        await expectLater(assemble(), throwsArgumentError);
        expect(
          await File('${output.path}/module.wasm').readAsString(),
          'author edit',
        );
      },
    );

    test(
      'new generated paths cannot overwrite author files or directories',
      () async {
        await assemble();
        await Directory('${output.path}/core.wasm').create();
        await File('${output.path}/core.wasm/keep').writeAsString('keep');
        for (final name in wasmCallFiles) {
          await File('${source.path}/$name').writeAsString(name);
        }
        await expectLater(assemble(), throwsArgumentError);
        expect(
          await File('${output.path}/core.wasm/keep').readAsString(),
          'keep',
        );
      },
    );

    test('a generated parent path cannot replace an author file', () async {
      await assemble();
      final author = await File('${output.path}/wasm')
          .writeAsString('keep parent');
      final ownership = (await PackageOwnership.read(output))!;
      final staging = await root.createTemp('merge-');
      await expectLater(
        ownership.copyAuthors(staging, {'wasm/module.wasm'}),
        throwsArgumentError,
      );
      expect(await author.readAsString(), 'keep parent');
      expect(
        await File('${output.path}/module.wasm').readAsString(),
        'first module.wasm',
      );
    });

    test('equivalent generated names cannot replace author content', () async {
      await assemble();
      final author = await File('${output.path}/Core.wasm')
          .writeAsString('keep');
      if (!await File('${output.path}/core.wasm').exists()) {
        markTestSkipped('This filesystem distinguishes case.');
        return;
      }
      for (final name in wasmCallFiles) {
        await File('${source.path}/$name').writeAsString('generated');
      }
      await expectLater(assemble(), throwsArgumentError);
      expect(await author.readAsString(), 'keep');
      expect((await package())['version'], '1.0.0');
    });

    for (final parentFile in [true, false]) {
      test(
        'equivalent dual layout ${parentFile ? 'parent' : 'child'} conflicts preserve authors',
        () async {
          await assemble();
          final author = File(
            '${output.path}/WASM${parentFile ? '' : '/MODULE.WASM'}',
          );
          await author.parent.create(recursive: true);
          await author.writeAsString('keep');
          if (!await FileSystemEntity.identical(
            '${output.path}/WASM',
            '${output.path}/wasm',
          )) {
            markTestSkipped('This filesystem distinguishes case.');
            return;
          }
          final ownership = (await PackageOwnership.read(output))!;
          final staging = await root.createTemp('merge-equivalent-');
          await expectLater(
            ownership.copyAuthors(staging, {'wasm/module.wasm'}),
            throwsArgumentError,
          );
          expect(await author.readAsString(), 'keep');
        },
      );
    }

    for (final names in [
      ['Output', 'output'],
      ['caf\u00e9', 'cafe\u0301'],
    ]) {
      test('equivalent input/output ancestors are rejected: $names', () async {
        final parent = await Directory('${root.path}/${names[0]}').create();
        final alias = Directory('${root.path}/${names[1]}');
        if (!await alias.exists() ||
            !await FileSystemEntity.identical(parent.path, alias.path)) {
          markTestSkipped('This filesystem distinguishes these names.');
          return;
        }
        output = parent;
        source = await Directory('${alias.path}/module').create();
        for (final name in wasmPackageFiles) {
          await File('${source.path}/$name').writeAsString('keep');
        }
        await expectLater(
          assemble(),
          throwsA(
            isA<ArgumentError>().having(
              (error) => error.message,
              'message',
              contains('must not contain one another'),
            ),
          ),
        );
        expect(await parent.list().length, 1);
        // The reverse direction also rejects a not-yet-created child output.
        output = Directory('${parent.path}/module/new-output');
        await expectLater(
          assemble(),
          throwsA(
            isA<ArgumentError>().having(
              (error) => error.message,
              'message',
              contains('must not contain one another'),
            ),
          ),
        );
        expect(await output.exists(), isFalse);
      });
    }

    for (final field in ['type', 'files', 'exports', 'main']) {
      test('rejects author edits to generated $field', () async {
        await assemble();
        await editPackage((value) {
          value[field] = 'changed';
        });
        final before = await File('${output.path}/package.json').readAsString();
        await expectLater(
          assemble(),
          throwsA(anyOf(isA<ArgumentError>(), isA<FormatException>())),
        );
        expect(
          await File('${output.path}/package.json').readAsString(),
          before,
        );
      });
    }

    test(
      'manifest cannot claim an arbitrary author file even with its real hash',
      () async {
        await assemble();
        final file = File('${output.path}/$packageOwnershipFile');
        final value = jsonDecode(await file.readAsString()) as Map;
        (value['artifacts'] as Map)['author.txt'] =
            (value['artifacts'] as Map)['module.wasm'];
        await File('${output.path}/author.txt')
            .writeAsString('first module.wasm');
        await file.writeAsString(jsonEncode(value));
        await expectLater(assemble(), throwsFormatException);
        expect(
          await File('${output.path}/author.txt').readAsString(),
          'first module.wasm',
        );
      },
    );

    test(
      'output edits after snapshot are detected before publication',
      () async {
        await assemble();
        final ownership = (await PackageOwnership.read(output))!;
        await File('${output.path}/author.txt').writeAsString('changed');
        await expectLater(
          ownership.checkUnchanged(),
          throwsA(isA<FileSystemException>()),
        );
      },
    );

    test('unsupported author symlinks fail without dropping them', () async {
      await assemble();
      final link = await Link('${output.path}/author').create(source.path);
      await expectLater(assemble(), throwsArgumentError);
      expect(await link.target(), source.path);
    });

    test(
      'invalid Dart source preserves a previously assembled package',
      () async {
        await assemble();
        final before = await File('${output.path}/$packageOwnershipFile')
            .readAsString();
        await expectLater(
          buildPackage(
            library: File('${root.path}/missing.dart').uri,
            output: output,
            metadata: metadata,
          ),
          throwsA(isA<Exception>()),
        );
        expect(
          await File('${output.path}/$packageOwnershipFile').readAsString(),
          before,
        );
        expect(
          await File('${output.path}/module.wasm').readAsString(),
          'first module.wasm',
        );
      },
    );

    test(
      'a held lock fails before source analysis and is never unlinked',
      () async {
        await assemble();
        final lock = PackageLock.acquire(output);
        try {
          await expectLater(
            buildPackage(
              library: File('${root.path}/missing.dart').uri,
              output: output,
              metadata: metadata,
            ),
            throwsA(
              isA<FileSystemException>().having(
                (e) => e.message,
                'lock diagnostic',
                contains('holds the lock'),
              ),
            ),
          );
        } finally {
          lock.release();
        }
        expect(await lock.file.exists(), isTrue);
        await assemble();
      },
    );

    test(
      'inputs nested in existing output are rejected before analysis or copy',
      () async {
        await assemble();
        final ownedSource = await File('${output.path}/business.dart')
            .writeAsString('broken source');
        await expectLater(
          buildPackage(
            library: ownedSource.uri,
            output: output,
            metadata: metadata,
          ),
          throwsArgumentError,
        );
        await expectLater(
          assemble(assets: {'LICENSE': ownedSource}),
          throwsArgumentError,
        );
        final inside = BuiltModule(
          Directory('${output.path}/nested'),
          '3.13.5',
        );
        await expectLater(
          assembleWasmPackage(
            module: inside,
            output: output,
            metadata: metadata,
          ),
          throwsArgumentError,
        );
        expect(await ownedSource.readAsString(), 'broken source');
      },
    );

    test(
      'author file and directory modes, xattrs and ACLs survive replacement',
      () async {
        await assemble();
        final directory = await Directory('${output.path}/author').create();
        final file = await File('${directory.path}/data')
            .writeAsString('metadata');
        for (final entity in [
          directory,
          file,
          File('${output.path}/package.json'),
        ]) {
          final mode = entity is Directory ? '750' : '640';
          for (final command in [
            ['/bin/chmod', mode, entity.path],
            ['/usr/bin/xattr', '-w', 'test.napi.rebuild', 'kept', entity.path],
            ['/bin/chmod', '+a', 'everyone deny delete', entity.path],
          ]) {
            final result = await Process.run(
              command.first,
              command.skip(1).toList(),
            );
            expect(
              result.exitCode,
              0,
              reason: '${result.stdout}${result.stderr}',
            );
          }
        }
        addTearDown(() async {
          await Process.run('/bin/chmod', ['-RN', root.path]);
        });
        await File('${source.path}/module.wasm').writeAsString('after ACL');
        await assemble();
        expect(
          await File('${output.path}/module.wasm').readAsString(),
          'after ACL',
        );
        // Denied deletion leaves the old generation, but cannot change the
        // successful result or revert the newly committed package.
        expect(
          await root
              .list()
              .where(
                (entry) => entry.path
                    .split(Platform.pathSeparator)
                    .last
                    .startsWith('.napi-package-'),
              )
              .length,
          1,
        );
        for (final entity in [
          directory,
          file,
          File('${output.path}/package.json'),
        ]) {
          expect(
            (await entity.stat()).mode & 0x1ff,
            entity is Directory ? 0x1e8 : 0x1a0,
          );
          final attr = await Process.run('/usr/bin/xattr', [
            '-p',
            'test.napi.rebuild',
            entity.path,
          ]);
          expect(attr.exitCode, 0);
          expect((attr.stdout as String).trim(), 'kept');
          final acl = await Process.run('/bin/ls', ['-lde', entity.path]);
          expect(acl.exitCode, 0);
          expect(acl.stdout, contains('everyone deny delete'));
        }
      },
    );
  }, skip: !Platform.isMacOS);
}
