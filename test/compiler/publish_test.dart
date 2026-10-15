import 'dart:io';
import 'dart:isolate';

import 'package:napi/src/build/publish.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Directory source;
  late Directory target;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('napi-publish-');
    source = await Directory('${root.path}/staged artifacts').create();
    await File('${source.path}/marker').writeAsString('artifact');
    target = Directory('${root.path}/output 雪 🦆');
  });
  tearDown(() => root.delete(recursive: true));

  test('publishes a complete directory to a fresh Unicode path', () async {
    publishDirectory(source, target);
    expect(await source.exists(), isFalse);
    expect(await File('${target.path}/marker').readAsString(), 'artifact');
  });

  for (final kind in ['empty directory', 'populated directory', 'file']) {
    test('never replaces an existing $kind', () async {
      if (kind == 'file') {
        await File(target.path).writeAsString('keep');
      } else {
        await target.create();
        if (kind == 'populated directory') {
          await File('${target.path}/keep').writeAsString('keep');
        }
      }
      expect(
        () => publishDirectory(source, target),
        throwsA(isA<FileSystemException>()),
      );
      expect(await File('${source.path}/marker').readAsString(), 'artifact');
      if (kind == 'file') {
        expect(await File(target.path).readAsString(), 'keep');
      } else {
        expect(await target.list().length, kind == 'empty directory' ? 0 : 1);
        if (kind == 'populated directory') {
          expect(await File('${target.path}/keep').readAsString(), 'keep');
        }
      }
    });
  }

  for (final kind in ['directory', 'file', 'missing']) {
    test('never follows or replaces a symlink to a $kind', () async {
      final linkedPath = '${root.path}/linked';
      if (kind == 'directory') {
        await Directory(linkedPath).create();
        await File('$linkedPath/keep').writeAsString('keep');
      } else if (kind == 'file') {
        await File(linkedPath).writeAsString('keep');
      }
      final link = await Link(target.path).create(linkedPath);
      final originalTarget = await link.target();
      expect(
        () => publishDirectory(source, target),
        throwsA(isA<FileSystemException>()),
      );
      expect(await link.target(), originalTarget);
      expect(await File('${source.path}/marker').readAsString(), 'artifact');
      if (kind == 'directory') {
        expect(await File('$linkedPath/keep').readAsString(), 'keep');
        expect(await Directory(linkedPath).list().length, 1);
      } else if (kind == 'file') {
        expect(await File(linkedPath).readAsString(), 'keep');
      } else {
        expect(
          await FileSystemEntity.type(linkedPath),
          FileSystemEntityType.notFound,
        );
      }
    });
  }

  test('two independent publishers have exactly one winner', () async {
    final second = await Directory('${root.path}/second').create();
    await File('${second.path}/marker').writeAsString('second');
    final fromPaths = [source.path, second.path];
    final toPath = target.path;
    final results = await Future.wait([
      for (final from in fromPaths)
        Isolate.run(() {
          try {
            publishDirectory(Directory(from), Directory(toPath));
            return true;
          } on FileSystemException {
            return false;
          }
        }),
    ]);
    expect(results.where((result) => result), hasLength(1));
    final winner = results.indexOf(true);
    expect(
      await File('${target.path}/marker').readAsString(),
      winner == 0 ? 'artifact' : 'second',
    );
    expect(await Directory(fromPaths[winner]).exists(), isFalse);
    expect(await Directory(fromPaths[1 - winner]).exists(), isTrue);
  });

  test(
    'failed rename leaves the staged artifacts and target untouched',
    () async {
      final missingParent = Directory('${root.path}/missing/output');
      expect(
        () => publishDirectory(source, missingParent),
        throwsA(isA<FileSystemException>()),
      );
      expect(await source.exists(), isTrue);
      expect(await missingParent.parent.exists(), isFalse);
    },
  );

  test('publishes paths longer than MAX_PATH', () async {
    var parent = root.path;
    for (var i = 0; i < 6; i++) {
      parent += '/${'segment' * 8}$i';
    }
    final longSource = await Directory('$parent/staged')
        .create(recursive: true);
    await File('${longSource.path}/marker').writeAsString('long path');
    final longTarget = Directory('$parent/output');
    expect(longTarget.absolute.path.length, greaterThan(260));
    publishDirectory(longSource, longTarget);
    expect(await File('${longTarget.path}/marker').readAsString(), 'long path');
    final competitor = await Directory('$parent/competitor').create();
    expect(
      () => publishDirectory(competitor, longTarget),
      throwsA(isA<FileSystemException>()),
    );
    expect(await competitor.exists(), isTrue);
  });

  test(
    'Windows publication supports normalized and extended-length paths',
    () async {
      final parent = await Directory('${root.path}/parent').create();
      // Explicit extended paths preserve literal trailing dots/spaces. Ordinary
      // Win32 paths instead use dart:io's normal slash/dot-segment handling.
      final extendedParent =
          r'\\?\' + parent.absolute.path.replaceAll('/', r'\');
      final paths = [
        '$extendedParent\\output.',
        '$extendedParent\\output ',
        '${parent.path}/nested/../output',
      ];
      for (final path in paths) {
        final staged = await parent.createTemp('staged-');
        await File('${staged.path}/marker').writeAsString(path);
        final output = Directory(path);
        publishDirectory(staged, output);
        expect(
          await File('${output.path}${Platform.pathSeparator}marker')
              .readAsString(),
          path,
        );
        final competitor = await parent.createTemp('competitor-');
        expect(
          () => publishDirectory(competitor, output),
          throwsA(isA<FileSystemException>()),
        );
        expect(
          await File('${output.path}${Platform.pathSeparator}marker')
              .readAsString(),
          path,
        );
        await output.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows,
  );

  test('NUL paths fail before calling native code', () async {
    expect(
      () => publishDirectory(source, Directory('${target.path}\x00suffix')),
      throwsArgumentError,
    );
    expect(await source.exists(), isTrue);
    expect(await target.exists(), isFalse);
  });
}
