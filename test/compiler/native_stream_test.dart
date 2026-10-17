import 'dart:io';

import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/native/entrypoint.dart';
import 'package:napi/src/compiler/native/loader.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

void main() {
  final packages = File('.dart_tool/package_config.json').absolute.path;
  for (final (name, source) in [
    (
      'without public classes',
      '''
import 'package:napi/napi.dart';
@NAPI() Stream<int> values() async* { yield 42; }
@NAPI() Stream<void> empty() => const Stream<void>.empty();
@NAPI() Stream<T> opaque<T>(T value) => Stream<T>.value(value);
''',
    ),
    (
      'with structural, resource and composite references',
      '''
import 'package:napi/napi.dart';
@NAPI() abstract class Left { Left._(); int left(); }
@NAPI() abstract class Right { Right._(); int right(); }
class Both implements Left, Right {
  int left() => 1;
  int right() => 2;
}
@NAPI() Stream<Left> references() => Stream<Left>.value(Both());
@NAPI(classPolicy: ClassPolicy.value)
class Value { final int number; Value(this.number); }
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Resource {
  Resource();
  Stream<List<(int, {String text})>> get values => Stream.value([(1, text: 'a')]);
  Stream<Value> snapshots(Resource other) => Stream.value(Value(2));
  Stream<int> taking(Future<int> Function(int) callback) async* { yield await callback(1); }
  void close() {}
}
''',
    ),
  ]) {
    test('stream adapters compile $name', () async {
      final directory = await Directory.systemTemp.createTemp('napi-stream-');
      addTearDown(() => directory.delete(recursive: true));
      final business = File('${directory.path}/business.dart');
      await business.writeAsString(source);
      final plan = validateNative(
        await AnnotationFrontend(
          packagesPath: packages,
          native: true,
        ).read(business.uri),
      );
      final entry = File('${directory.path}/entry.dart');
      await entry.writeAsString(emitNativeDart(plan));
      final compiled = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'aot-snapshot',
        '--packages=$packages',
        entry.path,
        '--output=${directory.path}/module.aot',
      ]);
      expect(
        compiled.exitCode,
        0,
        reason: '${compiled.stdout}${compiled.stderr}',
      );
    }, timeout: const Timeout(Duration(minutes: 2)));
  }

  test(
    'loader hides the iterator class and preserves iterator protocol',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'napi-stream-loader-',
      );
      addTearDown(() => directory.delete(recursive: true));
      await File('${directory.path}/module.mjs').writeAsString(
        emitNativeLoader(
          ['values'],
          hasFutures: true,
          streamClassName: r'$napiStream',
        ),
      );
      await File('${directory.path}/preload.cjs').writeAsString(r'''
Object.defineProperty(process, 'platform', {value: 'darwin'});
Object.defineProperty(process, 'arch', {value: 'arm64'});
require.extensions['.node'] = require.extensions['.js'];
''');
      await File('${directory.path}/bridge.node').writeAsString(r'''
const brands = new WeakSet();
function Iterator() { throw new TypeError('private constructor'); }
Iterator.prototype.next = function next() {
  if (!brands.has(this)) return Promise.reject(new TypeError('receiver'));
  return Promise.resolve(Object.assign(Object.create(null), {value: 42, done: false}));
};
Iterator.prototype.return = function close() {
  if (!brands.has(this)) return Promise.reject(new TypeError('receiver'));
  return Promise.resolve(Object.assign(Object.create(null), {value: undefined, done: true}));
};
exports.load = (path, reference, promise) => {
  globalThis.promiseFactory = promise;
  return globalThis.nativeBindings = {
    $napiStream: Iterator,
    values() {
      const iterator = Object.create(Iterator.prototype);
      brands.add(iterator);
      return iterator;
    },
  };
};
''');
      await File('${directory.path}/check.mjs').writeAsString(r'''
import assert from 'node:assert/strict';
import * as api from './module.mjs';
assert.deepEqual(Object.keys(api), ['values']);
assert.deepEqual(Object.keys(globalThis.nativeBindings), ['values']);
assert.equal(typeof globalThis.promiseFactory, 'function');
const iterator = api.values();
assert.equal(iterator[Symbol.asyncIterator](), iterator);
assert.equal(iterator.next.name, 'next');
assert.equal(iterator.next.length, 0);
assert.equal(iterator.return.length, 0);
assert.throws(() => new iterator.constructor(), TypeError);
assert.throws(() => new iterator.next(), TypeError);
assert.throws(() => new iterator.return(), TypeError);
const next = iterator.next;
await assert.rejects(next.call({}), TypeError);
const item = await iterator.next();
assert.equal(item.value, 42);
assert.equal(item.done, false);
const done = await iterator.return();
assert.equal(done.value, undefined);
assert.equal(done.done, true);
assert.equal(Object.getPrototypeOf(done), null);
''');
      final checked = await Process.run('node', [
        '--require',
        '${directory.path}/preload.cjs',
        '${directory.path}/check.mjs',
      ]);
      expect(checked.exitCode, 0, reason: '${checked.stdout}${checked.stderr}');
    },
  );
}
