import 'dart:convert';
import 'dart:io';

import 'package:napi/build.dart';
import 'package:test/test.dart';

import '../support/commands.dart';

void main() {
  final repository = Directory.current.absolute;
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('napi build script space ');
    root = Directory(await root.resolveSymbolicLinks());
  });
  tearDown(() => root.delete(recursive: true));

  test('a custom script provides help and diagnoses invalid options', () async {
    final script = File('${root.path}/prepare_addon.dart');
    await script.writeAsString('''
import 'dart:io';
import 'package:napi/build.dart';

Future<void> main(List<String> args) async {
  await PackageBuild(
    library: File('missing.dart').absolute.uri,
    output: Directory('npm-package'),
    name: '@napi/script-counter',
    version: '1.2.3',
  ).run(args);
}
''');
    for (final (arguments, diagnostic) in <(List<String>, String?)>[
      (['--help'], null),
      (['--unknown'], 'unknown'),
      (['--target', 'other'], 'target'),
    ]) {
      final result = await Process.run(Platform.resolvedExecutable, [
        '--packages=${repository.path}/.dart_tool/package_config.json',
        script.path,
        ...arguments,
      ], workingDirectory: root.path);
      if (diagnostic == null) {
        expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
        expect(result.stdout, contains('--target'));
        expect(result.stdout, contains('--output'));
      } else {
        expect(result.exitCode, isNot(0));
        expect(result.stderr, contains(diagnostic));
        expect(result.stderr, isNot(contains('Unhandled exception')));
      }
      expect(await Directory('${root.path}/npm-package').exists(), isFalse);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('conflicting package fields preserve existing output', () async {
    final output = await Directory('${root.path}/npm-package').create();
    final sentinel = File('${output.path}/author.txt');
    await sentinel.writeAsString('keep this file');
    for (final (metadata, diagnostic) in <(Map<String, Object?>, String)>[
      ({'name': '@napi/different'}, 'name'),
      ({'version': '9.0.0'}, 'version'),
      ({'exports': './author.js'}, 'exports'),
    ]) {
      await expectLater(
        () => PackageBuild(
          library: File('${root.path}/missing.dart').uri,
          output: output,
          name: '@napi/script-counter',
          version: '1.2.3',
          metadata: metadata,
        ).build(),
        throwsA(
          predicate<Object>((error) => error.toString().contains(diagnostic)),
        ),
      );
      expect(await sentinel.readAsString(), 'keep this file');
      expect(await output.list().length, 1);
    }
  });

  test(
    'an author script builds and ships a Wasm package with runtime options',
    () async {
      final author = await Directory('${root.path}/author project 雪').create();
      await File('${author.path}/pubspec.yaml').writeAsString('''
name: napi_script_author
publish_to: none
environment:
  sdk: '3.13.5'
dependencies:
  napi:
    path: ${jsonEncode(repository.path)}
''');
      await Directory('${author.path}/lib').create();
      await File('${author.path}/lib/seed.dart')
          .writeAsString('const initialValue = 7;\n');
      await File('${author.path}/lib/counter.dart').writeAsString('''
import 'package:napi/napi.dart';
import 'package:napi_script_author/seed.dart';

@NAPI()
class Counter {
  Counter([this.value = initialValue]);
  int value;
  int increment([int amount = 1]) => value += amount;
}
''');
      await File('${author.path}/README.md')
          .writeAsString('A counter built through a Dart script.\n');
      final script = File('${author.path}/tool/release_counter.dart');
      await script.parent.create();
      await script.writeAsString('''
import 'dart:io';
import 'package:napi/build.dart';

Future<void> main(List<String> args) async {
  await PackageBuild(
    library: File('lib/counter.dart').absolute.uri,
    output: Directory('unused-output'),
    name: '@napi/script-counter',
    version: '1.2.3',
    target: BuildTarget.native,
    targets: {BuildTarget.native, BuildTarget.wasm},
    packagesPath: File('.dart_tool/package_config.json').absolute.path,
    metadata: {
      'description': 'Build script consumer',
      'author': {'name': 'Package Author'},
    },
    assets: {'README.md': File('README.md')},
  ).run(args);
}
''');
      await run(Platform.resolvedExecutable, [
        'pub',
        'get',
        '--offline',
      ], cwd: author.path);
      // A file cannot be a runtime cache. Wasm selection must not use it.
      final nativeCache = File('${root.path}/not-a-runtime-cache');
      await nativeCache.writeAsString('not a directory');
      Future<ProcessResult> runScript() => Process.run(
        Platform.resolvedExecutable,
        [
          'run',
          'tool/release_counter.dart',
          '--target',
          'wasm',
          '--output',
          'npm output',
        ],
        workingDirectory: author.path,
        environment: {'NAPI_RUNTIME_CACHE': nativeCache.path},
      );
      final build = await runScript();
      expect(build.exitCode, 0, reason: '${build.stdout}${build.stderr}');
      final output = Directory('${author.path}/npm output');
      expect(await output.exists(), isTrue);
      expect(await Directory('${author.path}/unused-output').exists(), isFalse);
      expect(
        await Directory('${author.path}/tool/npm output').exists(),
        isFalse,
      );
      expect(await nativeCache.readAsString(), 'not a directory');
      final metadata = jsonDecode(
        await File('${output.path}/package.json').readAsString(),
      ) as Map<String, dynamic>;
      expect(metadata['name'], '@napi/script-counter');
      expect(metadata['version'], '1.2.3');
      expect(metadata['author'], {'name': 'Package Author'});
      expect(
        await File('${output.path}/README.md').readAsString(),
        'A counter built through a Dart script.\n',
      );
      final files = await output.list(recursive: true).toList();
      expect(files.any((file) => file.path.endsWith('.node')), isFalse);
      expect(files.any((file) => file.path.endsWith('.aot')), isFalse);

      final module = File('${output.path}/module.wasm');
      final originalModule = await module.readAsBytes();
      final library = File('${author.path}/lib/counter.dart');
      await library.writeAsString(
        (await library.readAsString()).replaceFirst(
          'value += amount',
          'value += missingAmount',
        ),
      );
      final failedBuild = await runScript();
      expect(failedBuild.exitCode, isNot(0));
      expect(failedBuild.stderr, contains('NAPI_DART'));
      expect(failedBuild.stderr, contains('missingAmount'));
      expect(failedBuild.stderr, isNot(contains('Unhandled exception')));
      expect(
        RegExp(
          r'^#\d+\s',
          multiLine: true,
        ).hasMatch(failedBuild.stderr as String),
        isFalse,
      );
      expect(await module.readAsBytes(), originalModule);

      final cache = '${root.path}/npm cache';
      final pack = await Process.run('npm', [
        'pack',
        '--ignore-scripts',
        '--json',
        '--cache',
        cache,
      ], workingDirectory: output.path);
      expect(pack.exitCode, 0, reason: '${pack.stdout}${pack.stderr}');
      final packed = (jsonDecode(pack.stdout as String) as List).single as Map;
      final archive = await File('${output.path}/${packed['filename']}')
          .copy('${root.path}/counter.tgz');
      await author.delete(recursive: true);
      final consumer = await Directory('${root.path}/npm consumer').create();
      await File('${consumer.path}/package.json')
          .writeAsString('{"private":true,"type":"module"}');
      await run('npm', [
        'install',
        '--offline',
        '--ignore-scripts',
        '--no-audit',
        '--no-fund',
        '--cache',
        cache,
        archive.path,
      ], cwd: consumer.path);
      await File('${consumer.path}/test.mjs').writeAsString('''
import assert from 'node:assert/strict';
import { Counter } from '@napi/script-counter';
const counter = new Counter();
assert.equal(counter.value, 7);
assert.equal(counter.increment(), 8);
assert.equal(counter.increment(undefined), 9);
assert.equal(counter.increment(3), 12);
assert.throws(() => counter.increment('3'), TypeError);
''');
      await File('${consumer.path}/consumer.mts').writeAsString('''
import { Counter } from '@napi/script-counter';
const counter = new Counter();
const value: number = counter.increment();
counter.value = value;
counter.increment(undefined);
// @ts-expect-error The generated API requires a numeric increment.
counter.increment('3');
''');
      await run('node', ['test.mjs'], cwd: consumer.path);
      await typescript(consumer, 'consumer.mts');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
