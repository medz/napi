import 'dart:convert';
import 'dart:io';

import 'package:napi/src/build/build.dart';
import 'package:napi/src/compiler/sdk_adapter/dart_sdk_adapter.dart';
import 'package:test/test.dart';

import '../../tool/scalar_fixture.dart';

const _kinds = [
  'empty directory',
  'populated directory',
  'file',
  'directory symlink',
  'file symlink',
  'dangling symlink',
];

Future<void> _createCompetitor(Directory root, String kind) async {
  final output = '${root.path}/output';
  if (kind.endsWith('symlink')) {
    final linked = '${root.path}/linked';
    if (kind == 'directory symlink') {
      await Directory(linked).create();
      await File('$linked/keep').writeAsString('keep');
    } else if (kind == 'file symlink') {
      await File(linked).writeAsString('keep');
    }
    await Link(output).create(linked);
  } else if (kind == 'file') {
    await File(output).writeAsString('keep');
  } else {
    await Directory(output).create();
    if (kind == 'populated directory') {
      await File('$output/keep').writeAsString('keep');
    }
  }
}

Future<void> _expectCompetitor(Directory root, String kind) async {
  final output = '${root.path}/output';
  if (kind.endsWith('symlink')) {
    final linked = '${root.path}/linked';
    expect(Uri.file(await Link(output).target()), Uri.file(linked));
    if (kind == 'directory symlink') {
      expect(await File('$linked/keep').readAsString(), 'keep');
      expect(await Directory(linked).list().length, 1);
    } else if (kind == 'file symlink') {
      expect(await File(linked).readAsString(), 'keep');
    } else {
      expect(
        await FileSystemEntity.type(linked),
        FileSystemEntityType.notFound,
      );
    }
  } else if (kind == 'file') {
    expect(await File(output).readAsString(), 'keep');
  } else {
    expect(
      await Directory(output).list().length,
      kind == 'empty directory' ? 0 : 1,
    );
    if (kind == 'populated directory') {
      expect(await File('$output/keep').readAsString(), 'keep');
    }
  }
  expect(
    await root
        .list()
        .where(
          (entry) => entry.uri.pathSegments
              .where((segment) => segment.startsWith('.napi-build-'))
              .isNotEmpty,
        )
        .length,
    0,
    reason: 'The build must remove its own staging directory.',
  );
}

String _quote(String value) => "'${value.replaceAll("'", "'\\''")}'";

// A POSIX executable hook runs after buildModule's initial destination check,
// then lets the real pinned compiler compile and link the fixture as usual.
Future<DartSdkAdapter> _racingSdk(Directory root, String kind) async {
  final sdk = Directory('${root.path}/sdk');
  final bin = await Directory('${sdk.path}/bin').create(recursive: true);
  final real = File(Platform.resolvedExecutable).parent.parent;
  await Link('${bin.path}/dartaotruntime')
      .create('${real.path}/bin/dartaotruntime');
  await Link('${bin.path}/snapshots').create('${real.path}/bin/snapshots');
  await Link('${sdk.path}/lib').create('${real.path}/lib');
  await Link('${sdk.path}/LICENSE').create('${real.path}/LICENSE');
  final hook = File('${root.path}/create_competitor.dart');
  await hook.writeAsString('''
import '${File('test/compiler/build_test.dart').absolute.uri}' show createCompetitor;
import 'dart:io';
Future<void> main() async {
  await createCompetitor(Directory(${_dartString(root.path)}), ${_dartString(kind)});
}
''');
  final executable = File('${bin.path}/dart');
  await executable.writeAsString('''#!/bin/sh
set -eu
${_quote(Platform.resolvedExecutable)} --packages=${_quote(File('.dart_tool/package_config.json').absolute.path)} ${_quote(hook.path)}
printf '%s\\n' 'Dart SDK version: $supportedDartSdkVersion (stable) (race hook)'
''');
  final chmod = await Process.run('chmod', ['+x', executable.path]);
  expect(chmod.exitCode, 0, reason: '${chmod.stdout}${chmod.stderr}');
  return DartSdkAdapter(executable: executable.path);
}

// Entrypoint for the separate version-hook process; not production API.
Future<void> createCompetitor(Directory root, String kind) =>
    _createCompetitor(root, kind);

String _dartString(String value) => jsonEncode(value).replaceAll(r'$', r'\$');

void main() {
  for (final kind in _kinds) {
    test('existing $kind is rejected without changing user files', () async {
      final root = await Directory.systemTemp.createTemp('napi-preserve-');
      addTearDown(() => root.delete(recursive: true));
      await _createCompetitor(root, kind);
      await expectLater(
        buildModule(
          bindings: scalarBindings(),
          output: Directory('${root.path}/output'),
        ),
        throwsArgumentError,
      );
      await _expectCompetitor(root, kind);
    });
    test(
      'a $kind created during compilation is preserved',
      () async {
        final root = await Directory.systemTemp.createTemp('napi-race-');
        addTearDown(() => root.delete(recursive: true));
        final sdk = await _racingSdk(root, kind);
        await expectLater(
          buildModule(
            bindings: scalarBindings(),
            output: Directory('${root.path}/output'),
            sdk: sdk,
            packagesPath: '.dart_tool/package_config.json',
          ),
          throwsA(isA<FileSystemException>()),
        );
        await _expectCompetitor(root, kind);
      },
      skip: Platform.isWindows
          ? 'The compiler hook uses a POSIX executable.'
          : false,
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }

  test('compiler failure removes staging without publishing output', () async {
    final root = await Directory.systemTemp.createTemp('napi-failed-build-');
    addTearDown(() => root.delete(recursive: true));
    final output = Directory('${root.path}/output');
    await expectLater(
      buildModule(
        bindings: scalarBindings(),
        output: output,
        sdk: DartSdkAdapter(executable: 'node'),
      ),
      throwsA(isA<SdkCompatibilityException>()),
    );
    expect(await output.exists(), isFalse);
    expect(await root.list().length, 0);
  });
}
