import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('a fresh Dart package builds through the public API', () async {
    final root = await Directory.systemTemp.createTemp('napi public consumer ');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/pubspec.yaml').writeAsString('''
name: napi_public_consumer
environment:
  sdk: ^3.13.5
dependencies:
  napi:
    path: ${jsonEncode(Directory.current.path)}
''');
    await Directory('${root.path}/lib').create();
    await File('${root.path}/lib/entry.dart').writeAsString('''
import 'package:napi/napi.dart';
@NAPI(name: 'increment')
int addOne(int value) => value + 1;
const _default = 6 * 7;
@NAPI()
int optional([int value = _default]) => value;
@NAPI()
int named(int base, {required int? value, int extra = _default}) => base + (value ?? 0) + extra;
''');
    await File('${root.path}/build.dart').writeAsString('''
import 'dart:io';
import 'package:napi/build.dart';
Future<void> main() async {
  final BuiltModule built = await buildLibrary(
    library: File('lib/entry.dart').absolute.uri,
    output: Directory('output'),
    packagesPath: File('.dart_tool/package_config.json').absolute.path,
  );
  if (!built.wasm.existsSync() || built.sdkVersion != '3.13.5') {
    throw StateError('Missing artifact or unexpected SDK');
  }
}
''');
    for (final arguments in [
      ['pub', 'get', '--offline'],
      ['analyze', '--fatal-infos'],
      ['run', 'build.dart'],
    ]) {
      final result = await Process.run(
        Platform.resolvedExecutable,
        arguments,
        workingDirectory: root.path,
      );
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    }
    await File('${root.path}/check.mjs').writeAsString('''
import { strict as assert } from 'node:assert';
import { increment, optional, named } from './output/module.wasm';
assert.equal(increment(41), 42);
assert.equal(optional(), 42);
assert.equal(optional(undefined), 42);
assert.equal(optional(0), 0);
assert.equal(named(1, {value: null}), 43);
assert.equal(named(1, {value: 0, extra: undefined}), 43);
assert.throws(() => named(1, {value: undefined}), TypeError);
''');
    final result = await Process.run('node', [
      'check.mjs',
    ], workingDirectory: root.path);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
