import 'dart:io';

import 'package:napi/src/build/build.dart';
import 'package:test/test.dart';

void main() {
  test(
    'void-only Futures and concrete cleanup compile and settle as undefined',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'napi-wasm-void-future-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final input = await File('${directory.path}/business.dart')
          .writeAsString('''
import 'package:napi/napi.dart';
int syncCount = 0;
int asyncCount = 0;
@NAPI() int syncCloses() => syncCount;
@NAPI() int asyncCloses() => asyncCount;
// No non-void Future or Stream may mask the constant-null converter branch.
@NAPI() Future<void> finish({bool fail = false}) async {
  await Future<void>.delayed(Duration.zero);
  if (fail) throw StateError('ordinary-failure');
}
class Session<T> {
  T value;
  Session(this.value);
  void close([bool fail = false]) {
    syncCount++;
    if (fail) throw StateError('cleanup-failure');
  }
}
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
typedef IntSession = Session<int>;
class Completion<T> {
  Completion();
  Future<T> close() async {
    asyncCount++;
    await Future<void>.delayed(Duration.zero);
    return Future<T>.value();
  }
}
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
typedef VoidSession = Completion<void>;
''');
      await buildLibrary(
        library: input.uri,
        output: Directory('${directory.path}/module'),
        packagesPath: File('.dart_tool/package_config.json').absolute.path,
      );
      await File('${directory.path}/check.mjs').writeAsString(r'''
import assert from 'node:assert/strict';
import * as api from './module/module.wasm';
const completion = api.finish();
assert(completion instanceof Promise);
assert.equal(await completion, undefined);
await assert.rejects(api.finish({fail: true}), /ordinary-failure/);
const resource = new api.IntSession(1);
const close = resource.close();
assert(close instanceof Promise);
assert.equal(resource.close(true), close);
assert.equal(await close, undefined);
assert.equal(api.syncCloses(), 1);
assert.throws(() => resource.value);
const failure = new api.IntSession(2);
const rejected = failure.close(true);
await assert.rejects(rejected, /cleanup-failure/);
assert.equal(failure.close(), rejected);
assert.equal(api.syncCloses(), 2);
const asynchronous = new api.VoidSession();
const asyncClose = asynchronous.close();
assert(asyncClose instanceof Promise);
assert.equal(asynchronous.close(), asyncClose);
assert.equal(await asyncClose, undefined);
assert.equal(api.asyncCloses(), 1);
''');
      final result = await Process.run('node', [
        'check.mjs',
      ], workingDirectory: directory.path);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
