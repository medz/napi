import 'dart:convert';
import 'dart:io';

import 'package:napi/src/build/build.dart';
import 'package:napi/src/build/package.dart';
import 'package:test/test.dart';

const _requiredFiles = [
  'module.wasm',
  'module.d.wasm.ts',
  'host.mjs',
  'boundary.mjs',
  'DART_LICENSE',
];
const _metadata = {'name': '@fixture/path', 'version': '1.2.3'};

void main() {
  late Directory root;
  late Directory source;
  late Directory output;
  late BuiltModule module;

  setUp(() async {
    final temp = Directory(await Directory.systemTemp.resolveSymbolicLinks());
    root = await temp.createTemp('napi package assembly ');
    source = await Directory('${root.path}/module').create();
    output = Directory('${root.path}/fresh package');
    module = BuiltModule(source, '3.13.5');
    for (final name in _requiredFiles) {
      await File('${source.path}/$name').writeAsString(name);
    }
  });
  tearDown(() => root.delete(recursive: true));

  Future<Directory> assemble({
    Map<String, Object?> metadata = _metadata,
    Map<String, File> assets = const {},
  }) => assembleWasmPackage(
    module: module,
    output: output,
    metadata: metadata,
    assets: assets,
  );

  test(
    'copies only known artifacts and explicit assets, retaining metadata',
    () async {
      await File('${source.path}/private.key').writeAsString('never copy');
      await File('${source.path}/package.json').writeAsString('never copy');
      final license = File('${root.path}/project license');
      await license.writeAsString('Project MIT license');
      final author = {'name': 'A', 'email': 'a@example.invalid'};
      await assemble(
        metadata: {
          ..._metadata,
          'author': author,
          'contributors': ['B'],
          'repository': {'type': 'git', 'url': 'https://example.invalid/repo'},
          'license': 'MIT',
        },
        assets: {'LICENSE': license},
      );
      final manifest = jsonDecode(
        await File('${output.path}/package.json').readAsString(),
      ) as Map;
      expect(manifest['author'], author);
      expect(manifest['contributors'], ['B']);
      expect(manifest['repository'], {
        'type': 'git',
        'url': 'https://example.invalid/repo',
      });
      expect(manifest['license'], 'MIT');
      expect(manifest['type'], 'module');
      expect(manifest['exports'], {
        for (final key in ['.', './module.wasm'])
          key: {'types': './module.d.wasm.ts', 'import': './module.wasm'},
      });
      expect(manifest['files'], [..._requiredFiles, 'LICENSE']);
      expect(
        await output.list().map((file) => file.uri.pathSegments.last).toList(),
        unorderedEquals([..._requiredFiles, 'LICENSE', 'package.json']),
      );
      expect(
        await File('${output.path}/LICENSE').readAsString(),
        'Project MIT license',
      );
      expect(
        await File('${output.path}/DART_LICENSE').readAsString(),
        'DART_LICENSE',
      );
    },
  );

  test('optional callable artifacts must be complete', () async {
    await File('${source.path}/core.wasm').writeAsString('core');
    await expectLater(assemble(), throwsArgumentError);
    expect(await output.exists(), isFalse);
    await File('${source.path}/calls.mjs').writeAsString('calls');
    await expectLater(assemble(), throwsArgumentError);
    expect(await output.exists(), isFalse);
    await File('${source.path}/references.mjs').writeAsString('references');
    await assemble();
    expect(await File('${output.path}/core.wasm').readAsString(), 'core');
    expect(await File('${output.path}/calls.mjs').readAsString(), 'calls');
    expect(
      await File('${output.path}/references.mjs').readAsString(),
      'references',
    );
  });

  for (final field in [
    'exports',
    'files',
    'type',
    'main',
    'types',
    'imports',
    'browser',
  ]) {
    test('reports the exact conflicting generated field $field', () async {
      await expectLater(
        assemble(
          metadata: {
            ..._metadata,
            field: {'.': './other.mjs'},
          },
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            contains('"$field" conflicts'),
          ),
        ),
      );
      expect(await output.exists(), isFalse);
    });
  }

  test(
    'valid scoped built-in leaf names and prefix-only names stay legal',
    () async {
      for (final name in [
        '@scope/path',
        '@scope/_pkg',
        '@_scope/pkg',
        '@scope/-pkg',
        r"@a~'!()*._-/pkg",
        'test',
        'sqlite',
        'sea',
        'ffi',
      ]) {
        await assemble(metadata: {..._metadata, 'name': name});
        await output.delete(recursive: true);
      }
    },
  );

  test('invalid and unscoped built-in names fail without output', () async {
    for (final name in [
      'path',
      'fs',
      '-pkg',
      '_pkg',
      '.pkg',
      '@scope',
      '@scope/.pkg',
      '@scope/p~kg',
      '@sc%ope/pkg',
      '@scope/../path',
      'Uppercase',
      '../escape',
      '',
      'node_modules',
    ]) {
      await expectLater(
        assemble(metadata: {..._metadata, 'name': name}),
        throwsArgumentError,
      );
      expect(await output.exists(), isFalse, reason: name);
    }
  });

  test('invalid versions and non-JSON metadata fail before staging', () async {
    for (final version in [
      '',
      'v1.0.0',
      '1.0',
      '01.0.0',
      '9007199254740992.0.0',
      '1.9007199254740992.0',
      '1.0.9007199254740992',
      '1.0.0+${'a' * 251}',
    ]) {
      await expectLater(
        assemble(metadata: {..._metadata, 'version': version}),
        throwsArgumentError,
      );
    }
    await expectLater(
      assemble(metadata: {..._metadata, 'author': Object()}),
      throwsA(isA<JsonUnsupportedObjectError>()),
    );
    expect(await root.list().length, 1);
  });

  test(
    'asset traversal, reserved names and arbitrary file destinations fail',
    () async {
      final asset = File('${root.path}/license');
      await asset.writeAsString('license');
      for (final name in [
        '../LICENSE',
        '/LICENSE',
        r'doc\LICENSE',
        'doc/LICENSE',
        'host.mjs',
        'package.json',
        'install.sh',
      ]) {
        await expectLater(assemble(assets: {name: asset}), throwsArgumentError);
        expect(await output.exists(), isFalse);
      }
    },
  );

  test('missing required artifacts and license are rejected', () async {
    for (final name in _requiredFiles) {
      final file = File('${source.path}/$name');
      await file.delete();
      await expectLater(assemble(), throwsArgumentError);
      expect(await output.exists(), isFalse);
      await file.writeAsString(name);
    }
  });

  test(
    'symlinked artifact, asset and intermediate directories are rejected',
    () async {
      final external = File('${root.path}/external');
      await external.writeAsString('external');
      final wasm = File('${source.path}/module.wasm');
      await wasm.delete();
      await Link(wasm.path).create(external.path);
      await expectLater(assemble(), throwsArgumentError);
      await Link(wasm.path).delete();
      await wasm.writeAsString('wasm');
      final assetLink = Link('${root.path}/license link');
      await assetLink.create(external.path);
      await expectLater(
        assemble(assets: {'LICENSE': File(assetLink.path)}),
        throwsArgumentError,
      );
      final directoryLink = Link('${root.path}/directory link');
      await directoryLink.create(source.path);
      module = BuiltModule(Directory('${directoryLink.path}/.'), '3.13.5');
      await expectLater(assemble(), throwsArgumentError);
      expect(await output.exists(), isFalse);
    },
  );

  for (final kind in ['directory', 'file', 'symlink']) {
    test('existing $kind output is preserved', () async {
      if (kind == 'directory') {
        await output.create();
      } else if (kind == 'file') {
        await File(output.path).writeAsString('keep');
      } else {
        await Link(output.path).create(source.path);
      }
      await expectLater(assemble(), throwsArgumentError);
      if (kind == 'file') {
        expect(await File(output.path).readAsString(), 'keep');
      }
      if (kind == 'directory') {
        expect(await output.list().length, 0);
      }
      if (kind == 'symlink') {
        expect(await Link(output.path).target(), source.path);
      }
      expect(await root.list().length, 2);
    });
  }

  test('output inside the input and traversal paths are rejected', () async {
    for (final name in [
      '${source.path}/nested',
      '${root.path}/absent/../escape',
    ]) {
      output = Directory(name);
      await expectLater(assemble(), throwsArgumentError);
    }
    expect(await root.list().length, 1);
  });

  test(
    'concurrent assembly publishes once and removes its own staging',
    () async {
      final results = await Future.wait([
        for (var i = 0; i < 2; ++i)
          () async {
            try {
              await assemble(
                metadata: {..._metadata, 'description': 'publisher $i'},
              );
              return true;
            } on FileSystemException {
              return false;
            } on ArgumentError {
              return false;
            }
          }(),
      ]);
      expect(results.where((result) => result), hasLength(1));
      final manifest = jsonDecode(
        await File('${output.path}/package.json').readAsString(),
      ) as Map;
      expect(manifest['description'], 'publisher ${results.indexOf(true)}');
      expect(await root.list().length, 2);
      expect(await source.list().length, _requiredFiles.length);
    },
  );
}
