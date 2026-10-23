import 'dart:io';

import 'package:test/test.dart';

import '../support/fixtures/package_contents.dart';

void main() {
  const expected = {'package.json', 'module.wasm', 'DART_LICENSE'};
  Map<String, dynamic> packed(Iterable<String> names) => {
    'files': [
      for (final name in names) {'path': name},
    ],
  };

  test('tarball inventory allows reordered exact contents', () {
    verifyPackedFiles(packed(expected.toList().reversed), expected);
  });

  for (final (label, names) in [
    ('missing license', ['package.json', 'module.wasm']),
    ('extra source', [...expected, 'business.dart']),
    ('duplicate file', [...expected, 'module.wasm']),
  ]) {
    test('tarball inventory rejects $label', () {
      expect(
        () => verifyPackedFiles(packed(names), expected),
        throwsStateError,
      );
    });
  }

  test('installed inventory checks files and exact notice bytes', () async {
    final root = await Directory.systemTemp.createTemp(
      'napi package contents ',
    );
    addTearDown(() => root.delete(recursive: true));
    for (final name in expected) {
      await File('${root.path}/$name').writeAsString(name);
    }
    final notices = {'DART_LICENSE': 'DART_LICENSE'.codeUnits};
    await verifyInstalledPackage(root, expected, notices);
    await File('${root.path}/DART_LICENSE').writeAsString('dart_license');
    await expectLater(
      verifyInstalledPackage(root, expected, notices),
      throwsStateError,
    );
    await File('${root.path}/DART_LICENSE').writeAsString('DART_LICENSE');
    final extra = File('${root.path}/business.dart');
    await extra.writeAsString('unintended source');
    await expectLater(
      verifyInstalledPackage(root, expected, notices),
      throwsStateError,
    );
    await extra.delete();
    await Directory('${root.path}/staging').create();
    await expectLater(
      verifyInstalledPackage(root, expected, notices),
      throwsStateError,
    );
  });

  test('nested inventory allows only expected artifact directories', () async {
    final root = await Directory.systemTemp.createTemp('napi dual inventory ');
    addTearDown(() => root.delete(recursive: true));
    const files = {'package.json', 'wasm/module.wasm', 'native/DART_LICENSE'};
    for (final name in files) {
      final file = File('${root.path}/$name');
      await file.parent.create(recursive: true);
      await file.writeAsString(name);
    }
    final notices = {'native/DART_LICENSE': 'native/DART_LICENSE'.codeUnits};
    await verifyInstalledPackage(root, files, notices, recursive: true);
    await expectLater(
      verifyInstalledPackage(root, files, notices),
      throwsStateError,
    );
    final extra = await Directory('${root.path}/wasm/cache').create();
    await expectLater(
      verifyInstalledPackage(root, files, notices, recursive: true),
      throwsStateError,
    );
    await extra.delete();
    await File('${root.path}/native/DART_LICENSE').delete();
    await expectLater(
      verifyInstalledPackage(root, files, notices, recursive: true),
      throwsStateError,
    );
  });
}
