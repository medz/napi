import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:napi/src/build/watch.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('napi-watch-inputs-');
    root = Directory(await root.resolveSymbolicLinks());
  });
  tearDown(() => root.delete(recursive: true));

  Future<File> write(String name, String contents) async {
    final file = File(path.normalize(path.join(root.path, name)));
    await file.parent.create(recursive: true);
    return file.writeAsString(contents);
  }

  test(
    'tracks directives, conditional branches, assets and missing files',
    () async {
      final config = await write(
        '.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'helper', 'rootUri': '../helper', 'packageUri': 'lib/'},
          ],
        }),
      );
      final entry = await write('lib/counter.dart', '''
import 'dart:core';
import 'package:helper/seed.dart';
export 'fallback.dart' if (dart.library.io) 'native.dart';
part 'counter.g.dart';
void invalid(;
''');
      await write('helper/lib/seed.dart', "export '../../shared.dart';");
      await write('shared.dart', 'const seed = 1;');
      await write('lib/fallback.dart', '');
      await write('lib/native.dart', '');
      final asset = await write('README.md', 'Counter');
      final files = await readBuildInputs(entry.uri, assets: [asset]);
      expect(
        files.keys,
        unorderedEquals(
          [
            config.path,
            entry.path,
            '${root.path}/helper/lib/seed.dart',
            '${root.path}/shared.dart',
            '${root.path}/lib/fallback.dart',
            '${root.path}/lib/native.dart',
            '${root.path}/lib/counter.g.dart',
            asset.path,
          ].map(path.normalize),
        ),
      );
      expect(files[path.join(root.path, 'lib', 'counter.g.dart')], isNull);
      final external = await readBuildInputs(
        Uri.parse('package:helper/seed.dart'),
        packagesPath: config.path,
      );
      expect(external.keys, contains(path.join(root.path, 'shared.dart')));
    },
  );

  test('invalid import URIs remain recoverable while editing', () async {
    final entry = await write('counter.dart', '''
import 'package:helper';
import 'package://helper/a.dart';
import 'file:///tmp/source.dart?edit';
''');
    final invalid = await readBuildInputs(entry.uri);
    expect(invalid.keys, contains(entry.path));
    await entry.writeAsString("import 'source.dart';");
    final repaired = await readBuildInputs(entry.uri);
    expect(repaired.keys, contains(path.join(root.path, 'source.dart')));
    expect(repaired[entry.path], isNot(invalid[entry.path]));
  });

  test('saves during a build are serialized and stop waits for it', () async {
    final entry = await write('counter.dart', 'const value = 1;');
    final stop = StreamController<void>();
    final started = StreamController<int>();
    final starts = StreamIterator(started.stream);
    final first = Completer<void>();
    final second = Completer<void>();
    var count = 0;
    var active = 0;
    final watching = watchBuild(
      library: entry.uri,
      output: Directory('${root.path}/dist'),
      stop: stop.stream,
      build: () async {
        expect(++active, 1);
        started.add(++count);
        await (count == 1 ? first.future : second.future);
        active--;
      },
    );
    var ended = false;
    unawaited(watching.then((_) => ended = true));
    try {
      expect(
        await starts.moveNext().timeout(const Duration(seconds: 5)),
        isTrue,
      );
      await entry.writeAsString('const value = 2;');
      await entry.writeAsString('const value = 3;');
      first.complete();
      expect(
        await starts.moveNext().timeout(const Duration(seconds: 5)),
        isTrue,
      );
      expect(count, 2);
      stop.add(null);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(ended, isFalse);
      second.complete();
      await watching.timeout(const Duration(seconds: 5));
      expect(count, 2);
    } finally {
      if (!first.isCompleted) first.complete();
      if (!second.isCompleted) second.complete();
      stop.add(null);
      await watching;
      await stop.close();
      await starts.cancel();
      await started.close();
    }
  });

  test('retargeting a dependency link follows the new directory', () async {
    final first = await write('first/value.dart', 'const value = 1;');
    final second = await write('second/value.dart', 'const value = 2;');
    final link = await Link(path.join(root.path, 'dependency'))
        .create(first.parent.path);
    final entry = await write(
      'counter.dart',
      "import 'dependency/value.dart';",
    );
    final stop = StreamController<void>();
    final built = StreamController<String>();
    final builds = StreamIterator(built.stream);
    final watching = watchBuild(
      library: entry.uri,
      output: Directory(path.join(root.path, 'dist')),
      stop: stop.stream,
      build: () async => built.add(
        await File(path.join(link.path, 'value.dart')).readAsString(),
      ),
    );
    Future<void> expectBuild(String contents) async {
      expect(
        await builds.moveNext().timeout(const Duration(seconds: 10)),
        isTrue,
      );
      expect(builds.current, contents);
    }

    try {
      await expectBuild('const value = 1;');
      await link.update(second.parent.path);
      await expectBuild('const value = 2;');
      await second.writeAsString('const value = 3;');
      await expectBuild('const value = 3;');
    } finally {
      stop.add(null);
      await watching;
      await stop.close();
      await builds.cancel();
      await built.close();
    }
  });
}
