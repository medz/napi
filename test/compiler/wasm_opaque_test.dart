import 'dart:io';

import 'package:napi/src/build/build.dart';
import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/dart/entrypoint.dart';
import 'package:napi/src/compiler/emit/js/arguments.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/sdk_adapter/dart_sdk_adapter.dart';
import 'package:test/test.dart';

final _packages = File('.dart_tool/package_config.json').absolute.path;

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-wasm-opaque-');
    addTearDown(() => directory.delete(recursive: true));
  });

  Future<ModulePlan> plan(String source) async {
    final input = File('${directory.path}/business.dart');
    await input.writeAsString(source);
    return lower(
      validate(
        await AnnotationFrontend(packagesPath: _packages).read(input.uri),
      ),
    );
  }

  test(
    'opaque functions and classes compile with actual carrier arguments',
    () async {
      final module = await plan('''
import 'package:napi/napi.dart';
@NAPI()
class Router<T> {
  Router([this.value]);
  Router.empty() : value = null;
  T? value;
  T identity(T next) => next;
  T? optional([T? next]) => next;
  T? named({required T? next}) => next;
  Router<T> same() => this;
  static int count() => 3;
}
@NAPI() T identity<T>(T value) => value;
@NAPI() T? optional<T>([T? value]) => value;
@NAPI() Router<T> reference<T>(Router<T> value) => value;
@NAPI() Future<int> pending<T>(T value) => Future.value(4);
''');
      final code = emitDart(module);
      expect(code, contains('final WasmExternRef? value;'));
      expect(code, contains('target.identity<_NapiHostValue>(a0)'));
      expect(code, contains('target.Router<_NapiHostValue>(a0)'));
      expect(code, contains('target.Router<_NapiHostValue>.empty()'));
      expect(code, contains('object is target.Router<_NapiHostValue>'));
      expect(code, contains('as target.Router<_NapiHostValue>'));
      expect(code, contains('target.Router.count()'));
      expect(code, isNot(contains('target.Router<_NapiHostValue>.count()')));
      expect(code, contains('a0 = _NapiHostValue(p0);'));
      expect(code, contains('return value.value;'));
      expect(
        code,
        contains('WasmAnyRef.fromObject(<Object?>[a0]).externalize()'),
      );
      final calls = emitArgumentCalls(module);
      expect(calls, contains('"opaqueRequired"'));
      expect(calls, contains('"opaqueOptional"'));
      expect(calls, contains('arguments.length === 0 ? [] : [value]'));
      final entry = File('${directory.path}/entrypoint.dart');
      await entry.writeAsString(code);
      final compiled = await DartSdkAdapter().compile(
        sourcePath: entry.path,
        outputPath: '${directory.path}/module.wasm',
        packagesPath: _packages,
      );
      expect(File(compiled.wasmPath).lengthSync(), greaterThan(0));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'phantom opaque parameters still instantiate their Dart carrier',
    () async {
      final code = emitDart(
        await plan('''
import 'package:napi/napi.dart';
@NAPI() class Marker<T> { Marker(); }
@NAPI() int value<T>() => 3;
'''),
      );
      expect(code, contains('final class _NapiHostValue'));
      expect(code, contains('target.Marker<_NapiHostValue>()'));
      expect(code, contains('target.value<_NapiHostValue>()'));
      final entry = File('${directory.path}/entrypoint.dart');
      await entry.writeAsString(code);
      await DartSdkAdapter().compile(
        sourcePath: entry.path,
        outputPath: '${directory.path}/module.wasm',
        packagesPath: _packages,
      );
    },
  );

  test('ordinary modules do not emit opaque storage', () async {
    final code = emitDart(
      await plan('''
import 'package:napi/napi.dart';
@NAPI() int value(int number) => number;
'''),
    );
    expect(code, isNot(contains('_NapiHostValue')));
    expect(code, contains('target.value(a0)'));
  });

  test('nested-only opaque modules preserve raw leaves', () async {
    final input = await File('${directory.path}/business.dart')
        .writeAsString('''
import 'package:napi/napi.dart';
@NAPI() List<T> copy<T>(List<T> value) => value;
@NAPI() List<bool> nulls<T>(List<T?> value) => [for (final item in value) item == null];
@NAPI() List<T?> withNull<T>(List<T> value) => [null, ...value];
@NAPI() Future<({T then})> thenRoot<T>(List<T> value) async => (then: value.first);
''');
    await buildLibrary(
      library: input.uri,
      output: Directory('${directory.path}/module'),
      packagesPath: _packages,
    );
    await File('${directory.path}/check.mjs').writeAsString(r'''
import assert from 'node:assert/strict';
import * as api from './module/module.wasm';
const hostile = new Proxy({}, { get() { throw Error('payload get'); } });
for (const value of [undefined, null, -0, NaN, Symbol(), 1n << 100n, hostile]) {
  const input = [value];
  const result = api.copy(input);
  assert.notEqual(result, input);
  assert(Object.is(result[0], value));
}
assert.deepEqual(api.nulls([null, undefined]), [false, false]);
assert.deepEqual(api.withNull([undefined]), [null, undefined]);
assert.throws(() => api.copy(), TypeError);
assert.throws(() => api.copy(Array(1)), TypeError);
assert.equal(await api.thenRoot([resolve => resolve(42)]), 42);
''');
    final result = await Process.run('node', [
      'check.mjs',
    ], workingDirectory: directory.path);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
    'Future payloads preserve raw values through standard Promise resolution',
    () async {
      final input = await File('${directory.path}/business.dart')
          .writeAsString('''
import 'package:napi/napi.dart';
@NAPI() Future<T> later<T>(T value) => Future.value(value);
@NAPI() Future<T?> optional<T>([T? value]) async => value;
@NAPI() Future<void> empty() async {}
@NAPI() class Box<T> {
  Box(this.value);
  T value;
  Future<T> get pending => Future.value(value);
}
''');
      await buildLibrary(
        library: input.uri,
        output: Directory('${directory.path}/module'),
        packagesPath: _packages,
      );
      await File('${directory.path}/check.mjs').writeAsString(r'''
import assert from 'node:assert/strict';
import {later, optional, empty, Box} from './module/module.wasm';
const object = {};
const fn = () => 1;
for (const value of [undefined, null, false, 0, -0, NaN, Infinity, 4n, '\ud800', Symbol('opaque'), object, fn]) {
  assert(Object.is(await later(value), value));
  assert(Object.is(await optional(value), value));
  assert(Object.is(await new Box(value).pending, value));
}
assert.equal(await optional(), null);
assert.equal(await empty(), undefined);
let reads = 0;
let calls = 0;
const thenable = {
  get then() {
    reads++;
    return function(resolve, reject) {
      assert.equal(this, thenable);
      calls++;
      resolve(object);
      reject(new Error('second settlement'));
    };
  },
};
assert.equal(await later(thenable), object);
assert.equal(reads, 1);
assert.equal(calls, 1);
for (const reason of [undefined, null, Symbol('thrown'), object]) {
  const throwing = {get then() { throw reason; }};
  let rejected = false;
  try { await later(throwing); }
  catch (error) { rejected = true; assert.equal(error, reason); }
  assert(rejected);
}
const nested = {value: thenable};
assert.equal(await later(nested), nested);
assert.equal((await later([thenable]))[0], thenable);
assert.equal(reads, 1, 'Promise resolution does not traverse nested payloads');
assert.equal(new Box(thenable).value, thenable);
assert.equal(reads, 1, 'synchronous values do not trigger Promise resolution');
''');
      final execution = await Process.run('node', [
        'check.mjs',
      ], workingDirectory: directory.path);
      expect(
        execution.exitCode,
        0,
        reason: '${execution.stdout}${execution.stderr}',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
