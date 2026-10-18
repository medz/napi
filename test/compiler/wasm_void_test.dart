import 'dart:io';

import 'package:napi/build.dart';
import 'package:test/test.dart';

import '../../tool/command.dart' show run;

void main() {
  test(
    'an all-void module without parameters loads and returns undefined',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'napi-void-only-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final source = await File('${directory.path}/business.dart')
          .writeAsString('''
import 'package:napi/napi.dart';
@NAPI() void empty() {}
@NAPI() void fail() => throw StateError('void-only-error');
''');
      await buildLibrary(
        library: source.uri,
        output: Directory('${directory.path}/module'),
        packagesPath: File('.dart_tool/package_config.json').absolute.path,
      );
      await File('${directory.path}/check.mjs').writeAsString('''
import assert from 'node:assert/strict';
import {empty, fail} from './module/module.wasm';
assert.equal(empty(), undefined);
assert.throws(() => fail(), /void-only-error/);
assert.equal(empty(), undefined);
''');
      await run('node', ['check.mjs'], cwd: directory.path);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
