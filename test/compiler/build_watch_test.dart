import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../support/commands.dart';

void main() {
  test(
    'watch rebuilds dependencies and recovers without replacing good output',
    () async {
      final repository = Directory.current.absolute;
      var root = await Directory.systemTemp.createTemp('napi watch space 雪 ');
      root = Directory(await root.resolveSymbolicLinks());
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });

      final dependency = await Directory('${root.path}/dependency/lib/src')
          .create(recursive: true);
      await File('${root.path}/dependency/pubspec.yaml').writeAsString('''
name: watch_values
environment:
  sdk: '3.13.5'
''');
      final values = File('${dependency.parent.path}/values.dart');
      await values.writeAsString("part 'src/value.dart';\n");
      final part = File('${dependency.path}/value.dart');
      Future<void> setValue(String expression) => part.writeAsString('''
part of '../values.dart';
const current = $expression;
''');
      await setValue('7');

      final author = await Directory('${root.path}/author/lib')
          .create(recursive: true);
      final project = author.parent;
      await File('${project.path}/pubspec.yaml').writeAsString('''
name: napi_watch_author
publish_to: none
environment:
  sdk: '3.13.5'
dependencies:
  napi:
    path: ${jsonEncode(repository.path)}
  watch_values:
    path: ../dependency
''');
      await File('${author.path}/relay.dart')
          .writeAsString("export 'package:watch_values/values.dart';\n");
      await File('${author.path}/counter.dart').writeAsString('''
import 'package:napi/napi.dart';
import 'relay.dart' as data;

@NAPI()
int value() => data.current;
''');
      await File('${project.path}/ship.dart').writeAsString('''
import 'dart:io';
import 'package:napi/build.dart';

final package = PackageBuild(
  library: File('lib/counter.dart').absolute.uri,
  output: Directory('npm-package'),
  name: '@napi/watch-counter',
  version: '1.0.0',
  packagesPath: File('.dart_tool/package_config.json').absolute.path,
);

Future<void> main(List<String> args) => package.run(args);
''');
      await run(Platform.resolvedExecutable, [
        'pub',
        'get',
        '--offline',
      ], cwd: project.path);

      final watcher = await Process.start(Platform.resolvedExecutable, [
        'run',
        'ship.dart',
        '--watch',
      ], workingDirectory: project.path);
      final lines = <String>[];
      final changed = StreamController<void>.broadcast(sync: true);
      void record(String line) {
        lines.add(line);
        changed.add(null);
      }

      final output = watcher.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(record);
      final errors = watcher.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(record);
      int? finished;
      unawaited(
        watcher.exitCode.then((code) {
          finished = code;
          changed.add(null);
        }),
      );
      addTearDown(() async {
        if (finished == null) {
          watcher.kill(ProcessSignal.sigint);
          try {
            await watcher.exitCode.timeout(const Duration(seconds: 15));
          } on TimeoutException {
            watcher.kill(ProcessSignal.sigkill);
            await watcher.exitCode;
          }
        }
        await output.cancel();
        await errors.cancel();
        await changed.close();
      });

      Future<void> waitFor(bool Function() condition) async {
        bool ready() {
          if (condition()) return true;
          if (finished != null) {
            throw StateError('Watcher exited $finished:\n${lines.join('\n')}');
          }
          return false;
        }

        if (ready()) return;
        await changed.stream
            .firstWhere((_) => ready())
            .timeout(
              const Duration(seconds: 90),
              onTimeout: () => throw TimeoutException(
                'No expected watch result:\n${lines.join('\n')}',
              ),
            );
      }

      int builds() => lines.where((line) => line.startsWith('Built ')).length;
      int failures() => lines
          .where((line) => line.startsWith('NAPI_') || line.startsWith('napi:'))
          .length;
      final package = Directory('${project.path}/npm-package');
      final module = File('${package.path}/module.wasm');
      final declarations = File('${package.path}/module.d.wasm.ts');
      Future<void> expectValue(int expected) => run('node', [
        '--input-type=module',
        '-e',
        '''import assert from 'node:assert/strict';
import { value } from ${jsonEncode(module.uri.toString())};
assert.equal(value(), $expected);''',
      ], cwd: project.path);

      await waitFor(() => builds() >= 1);
      await expectValue(7);

      var previousBuilds = builds();
      await setValue('8');
      await waitFor(() => builds() > previousBuilds);
      await expectValue(8);

      var goodModule = await module.readAsBytes();
      var goodDeclarations = await declarations.readAsString();
      var previousFailures = failures();
      await setValue('');
      await waitFor(() => failures() > previousFailures);
      expect(await module.readAsBytes(), goodModule);
      expect(await declarations.readAsString(), goodDeclarations);
      await expectValue(8);

      previousBuilds = builds();
      await setValue('9');
      await waitFor(() => builds() > previousBuilds);
      await expectValue(9);

      goodModule = await module.readAsBytes();
      goodDeclarations = await declarations.readAsString();
      previousFailures = failures();
      await values.writeAsString('''
import 'src/missing.dart';
const current = extra;
''');
      await waitFor(() => failures() > previousFailures);
      expect(await module.readAsBytes(), goodModule);
      expect(await declarations.readAsString(), goodDeclarations);

      previousBuilds = builds();
      final saved = File('${dependency.path}/editor-save.tmp');
      await saved.writeAsString('const extra = 10;\n');
      await saved.rename('${dependency.path}/missing.dart');
      await waitFor(() => builds() > previousBuilds);
      await expectValue(10);

      previousBuilds = builds();
      await File('${package.path}/notes.txt').writeAsString('author notes\n');
      await File('${author.path}/unrelated.dart').writeAsString('not Dart\n');
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(builds(), previousBuilds, reason: lines.join('\n'));

      expect(watcher.kill(ProcessSignal.sigint), isTrue);
      expect(
        await watcher.exitCode.timeout(const Duration(seconds: 15)),
        0,
        reason: lines.join('\n'),
      );
    },
    skip: !(Platform.isMacOS || Platform.isLinux)
        ? 'Managed output replacement is supported on macOS and Linux.'
        : false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
