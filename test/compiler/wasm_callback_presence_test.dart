import 'dart:io';

import 'package:napi/src/build/build.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Wasm typed callbacks preserve optional and named argument presence',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'napi-wasm-callback-presence-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final input = await File('${temporary.path}/business.dart')
          .writeAsString('''
import 'package:napi/napi.dart';
@NAPI() List<int> positional(int Function(int, [int?, int?]) callback) =>
    [callback(1), callback(1, null), callback(1, 2, 3)];
@NAPI() List<int> named(int Function(int, {int? count, String? text}) callback) =>
    [callback(1), callback(1, count: null), callback(1, text: 'x'), callback(1, count: 3, text: 'y')];
@NAPI() List<int> requiredNamed(int Function(int, {required int count, int? other}) callback) =>
    [callback(1, count: 2), callback(1, count: 3, other: null)];
@NAPI() int names(int Function({required int arguments, int? callback,
  int? operation, int? adapter, int? result, int? c0, int? constructor}) callback) =>
    callback(arguments: 1, callback: 2, operation: 3, adapter: 4, result: 5, c0: 6, constructor: 7);
@NAPI() List<int> opaque<T>(int Function([T?]) callback, T value) =>
    [callback(), callback(null), callback(value)];
@NAPI() List<int> opaqueNamed<T>(int Function({T? value}) callback, T value) =>
    [callback(), callback(value: null), callback(value: value)];
@NAPI() Future<List<int>> later(Future<int> Function({int? value}) callback) async =>
    [await callback(), await callback(value: null), await callback(value: 2)];
@NAPI() List<int> lists(int Function([List<int>?]) callback) =>
    [callback(), callback(null), callback([1])];
@NAPI() int handle(int Function([JsArray<int>?]) callback) => callback(null);
''');
      await buildLibrary(
        library: input.uri,
        output: Directory('${temporary.path}/module'),
        packagesPath: File('.dart_tool/package_config.json').absolute.path,
      );
      await File('${temporary.path}/check.mjs').writeAsString(r'''
import assert from 'node:assert/strict';
import * as api from './module/module.wasm';
let seen = [];
assert.deepEqual(api.positional(function(...args) { seen.push(args); return args.length; }), [1, 2, 3]);
assert.deepEqual(seen, [[1], [1, null], [1, 2, 3]]);
seen = [];
assert.deepEqual(api.named(function(...args) { seen.push(args); return args.length; }), [1, 2, 2, 2]);
assert.deepEqual(seen.map(args => args.length), [1, 2, 2, 2]);
assert.deepEqual(Object.keys(seen[1][1]), ['count']);
assert.equal(seen[1][1].count, null);
assert.deepEqual(Object.keys(seen[2][1]), ['text']);
assert.equal(seen[2][1].text, 'x');
assert.deepEqual({...seen[3][1]}, {count: 3, text: 'y'});
assert.equal(Object.getPrototypeOf(seen[1][1]), null);
seen = [];
assert.deepEqual(api.requiredNamed(function(...args) { seen.push(args); return args.length; }), [2, 2]);
assert.deepEqual({...seen[0][1]}, {count: 2});
assert.deepEqual({...seen[1][1]}, {count: 3, other: null});
assert.equal(api.names(options => {
  assert.equal(Object.getPrototypeOf(options), null);
  assert.deepEqual({...options}, {arguments: 1, callback: 2, operation: 3,
    adapter: 4, result: 5, c0: 6, constructor: 7});
  return 1;
}), 1);
for (const value of [undefined, null, Symbol('value'), {x: 1}]) {
  seen = [];
  assert.deepEqual(api.opaque(function(...args) { seen.push(args); return args.length; }, value), [0, 1, 1]);
  assert.equal(seen[1][0], null);
  assert.equal(seen[2][0], value);
  seen = [];
  assert.deepEqual(api.opaqueNamed(function(...args) { seen.push(args); return args.length; }, value), [0, 1, 1]);
  assert.equal(Object.hasOwn(seen[1][0], 'value'), true);
  assert.equal(seen[1][0].value, null);
  assert.equal(Object.hasOwn(seen[2][0], 'value'), true);
  assert.equal(seen[2][0].value, value);
}
seen = [];
assert.deepEqual(await api.later(async function(...args) { seen.push(args); return args.length; }), [0, 1, 1]);
assert.equal(seen[1][0].value, null);
assert.equal(seen[2][0].value, 2);
seen = [];
assert.deepEqual(api.lists(function(...args) { seen.push(args); return args.length; }), [0, 1, 1]);
assert.deepEqual(seen, [[], [null], [[1]]]);
assert.equal(api.handle(function(value) { assert.equal(arguments.length, 1); assert.equal(value, null); return 1; }), 1);
''');
      final execution = await Process.run('node', [
        'check.mjs',
      ], workingDirectory: temporary.path);
      expect(
        execution.exitCode,
        0,
        reason: '${execution.stdout}${execution.stderr}',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
