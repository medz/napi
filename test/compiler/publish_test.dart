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
    'Windows publication preserves pinned dart:io path normalization',
    () async {
      // Dart normalizes a terminal dot/space differently from an interior
      // segment, even in extended paths. Compare with Directory.renameSync
      // itself rather than claiming literal trailing-name support.
      for (final name in ['output.', 'output ', 'nested/../output']) {
        final expectedParent = await root.createTemp('expected-');
        final actualParent = await root.createTemp('actual-');
        final expectedSource = await Directory('${expectedParent.path}/staged')
            .create();
        final actualSource = await Directory('${actualParent.path}/staged')
            .create();
        await File('${expectedSource.path}/marker').writeAsString('keep');
        await File('${actualSource.path}/marker').writeAsString('keep');
        expectedSource.renameSync('${expectedParent.path}/$name');
        final output = Directory('${actualParent.path}/$name');
        publishDirectory(actualSource, output);
        expect(await actualSource.exists(), isFalse);
        expect(await expectedSource.exists(), isFalse);
        final expectedEntry = await expectedParent.list().single;
        final actualEntry = await actualParent.list().single;
        String basename(FileSystemEntity entry) =>
            entry.uri.pathSegments.where((segment) => segment.isNotEmpty).last;
        expect(basename(actualEntry), basename(expectedEntry));
        final marker = File(
          '${actualEntry.path}${Platform.pathSeparator}marker',
        );
        final expectedMarker = File(
          '${expectedEntry.path}${Platform.pathSeparator}marker',
        );
        expect(
          await marker.readAsString(),
          await expectedMarker.readAsString(),
        );
        final competitor = await actualParent.createTemp('competitor-');
        expect(
          () => publishDirectory(competitor, output),
          throwsA(isA<FileSystemException>()),
        );
        expect(await marker.readAsString(), 'keep');
        expect(await competitor.exists(), isTrue);
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

  test(
    'one exchange swaps populated directories without a missing name',
    () async {
      await target.create();
      await File('${target.path}/marker').writeAsString('old');
      checkPackageRebuildFilesystem(root);
      exchangeDirectories(source, target);
      expect(await File('${target.path}/marker').readAsString(), 'artifact');
      expect(await File('${source.path}/marker').readAsString(), 'old');
    },
    skip: !Platform.isMacOS,
  );

  test(
    'independent descriptors and isolates contend on one stable lock',
    () async {
      final lock = PackageLock.acquire(target);
      final outputPath = target.path;
      final lockFile = File('${target.path}.napi-lock');
      try {
        expect(
          () => PackageLock.acquire(target),
          throwsA(isA<FileSystemException>()),
        );
        expect(
          await Isolate.run(() {
            try {
              PackageLock.acquire(Directory(outputPath)).release();
              return false;
            } on FileSystemException {
              return true;
            }
          }),
          isTrue,
        );
        expect(await lockFile.exists(), isTrue);
      } finally {
        lock.release();
      }
      expect(await lockFile.exists(), isTrue);
      final next = PackageLock.acquire(target);
      try {
        // A competitor opens the same retained inode, rather than a new lock at
        // a name unlinked by the first builder.
        expect(
          () => PackageLock.acquire(target),
          throwsA(isA<FileSystemException>()),
        );
      } finally {
        next.release();
      }
      expect(await lockFile.exists(), isTrue);
    },
    skip: Platform.isWindows,
  );

  test('process exit releases a lock without deleting the inode', () async {
    final script = File('${root.path}/lock.dart');
    await script.writeAsString('''
import 'dart:io';
import 'package:napi/src/build/publish.dart';
Future<void> main(List<String> args) async {
  final lock = PackageLock.acquire(Directory(args.single));
  stdout.writeln('locked');
  await stdin.first;
  lock.release();
}
''');
    final child = await Process.start(Platform.resolvedExecutable, [
      '--packages=${File('.dart_tool/package_config.json').absolute.path}',
      script.path,
      target.path,
    ]);
    addTearDown(() {
      child.kill();
    });
    await child.stdout.first;
    expect(
      () => PackageLock.acquire(target),
      throwsA(isA<FileSystemException>()),
    );
    expect(child.kill(ProcessSignal.sigkill), isTrue);
    await child.exitCode;
    final next = PackageLock.acquire(target);
    next.release();
    expect(await File('${target.path}.napi-lock').exists(), isTrue);
  }, skip: Platform.isWindows);

  test('lock names reject symlinks without touching their targets', () async {
    final external = File('${root.path}/external');
    await Link('${target.path}.napi-lock').create(external.path);
    expect(
      () => PackageLock.acquire(target),
      throwsA(isA<FileSystemException>()),
    );
    expect(await external.exists(), isFalse);
  }, skip: Platform.isWindows);

  test(
    'postcommit cleanup failure succeeds; precommit cleanup still fails',
    () async {
      final residual = _DeleteFailure('${root.path}/build scratch');
      await cleanPackageStaging(residual, committed: true);
      expect(residual.attempts, 1);
      await expectLater(
        cleanPackageStaging(residual, committed: false),
        throwsA(isA<FileSystemException>()),
      );
      expect(residual.attempts, 2);
    },
  );
}

final class _DeleteFailure implements Directory {
  _DeleteFailure(this.path);
  @override
  final String path;
  int attempts = 0;
  @override
  Future<bool> exists() async => true;
  @override
  Future<Directory> delete({bool recursive = false}) async {
    attempts++;
    throw FileSystemException('injected cleanup failure', path);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
