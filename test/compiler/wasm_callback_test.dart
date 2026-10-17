import 'dart:io';

import 'package:napi/src/build/build.dart';
import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/dart/entrypoint.dart';
import 'package:napi/src/compiler/emit/js/arguments.dart';
import 'package:napi/src/compiler/emit/js/boundary.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/sdk_adapter/dart_sdk_adapter.dart';
import 'package:test/test.dart';

final _packages = File('.dart_tool/package_config.json').absolute.path;

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-wasm-callback-');
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
    'retained adapters compile both conversion directions and resource scopes',
    () async {
      final module = await plan('''
import 'package:napi/napi.dart';
@NAPI() int invoke(int Function(int) callback) => callback(2);
@NAPI() int optional([int Function(int)? callback]) => callback?.call(2) ?? 0;
@NAPI() BigInt wide(BigInt Function(BigInt) callback) => callback(BigInt.one);
@NAPI() (List<int>, {String label}) structured(
  (List<int>, {String label}) Function((List<int>, {String label})) callback,
) => callback(([1], label: 'a'));
@NAPI() int discard(void Function() callback) { callback(); return 0; }
@NAPI() Future<int> later() => Future.error(StateError('later'));
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Resource {
  Resource();
  int apply(int Function(int) callback) => callback(2);
  void close() {}
}
''');
      final code = emitDart(module);
      expect(code, contains('final class _CallbackThrown'));
      expect(code, contains('if (error is _CallbackThrown)'));
      expect(code, contains('return _throwCallbackError(error.envelope)'));
      expect(
        code,
        contains('_rejectCallbackPromise(capability, error.envelope)'),
      );
      expect(code, contains('BigInt.parse((value as JSString).toDart)'));
      final calls = emitArgumentCalls(module);
      expect(calls, isNot(contains('expireCallbacks')));
      expect(calls, contains('finally { finishResourceCall(capability); }'));
      final boundary = emitBoundary(module);
      expect(boundary, contains('const callbackApply = Reflect.apply;'));
      expect(
        boundary,
        contains('catch (value) { return {threw: true, value}; }'),
      );
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

  test('ordinary modules omit user callback adapters', () async {
    final module = await plan('''
import 'package:napi/napi.dart';
@NAPI() int increment(int value) => value + 1;
''');
    final code = emitDart(module);
    // Internal shared allocation needs exact host errors even for scalar APIs.
    expect(code, contains('_CallbackThrown'));
    expect(code, isNot(contains('_findCallbackAdapter')));
    expect(code, isNot(contains('_invokeCallback')));
    expect(emitArgumentCalls(module), isNot(contains('borrowed')));
    expect(emitBoundary(module), isNot(contains('callbackApply')));
  });

  test('callbacks retain identity and consume genuine Promises', () async {
    final input = await File('${directory.path}/business.dart')
        .writeAsString('''
import 'dart:async';
import 'package:napi/napi.dart';
final callbacks = <int Function(int)>[];
WeakReference<Function>? weak;
List<int>? pressure;
int asyncState = 0;
@NAPI() int store(int Function(int) callback) {
  callbacks.add(callback); return callbacks.length;
}
@NAPI() bool remove(int Function(int) callback) => callbacks.remove(callback);
@NAPI() int invoke(int value) => callbacks.last(value);
@NAPI() int remember(int Function(int) callback) { weak = WeakReference(callback); return 0; }
@NAPI() bool alive() => weak?.target != null;
@NAPI() int collect(int seed) {
  pressure = List<int>.generate(100000, (i) => seed + i);
  return pressure!.last;
}
@NAPI() Future<int> timer(int Function(int) callback) =>
    Future.delayed(Duration(milliseconds: 1), () => callback(4));
@NAPI() Future<int> asyncUse(Future<int> Function(int) callback) => callback(4);
@NAPI() bool catchStart(Future<int> Function(int) callback) {
  try { callback(4); return false; } catch (_) { return true; }
}
@NAPI() Future<void> asyncVoid(Future<void> Function() callback) => callback();
@NAPI() Future<List<int>> asyncList(Future<List<int>> Function(List<int>) callback) => callback([1, 2]);
@NAPI() int startAsync(Future<int> Function(int) callback) {
  weak = WeakReference(callback);
  asyncState = 0;
  callback(4).then((value) { asyncState = value; });
  return 0;
}
@NAPI() int readAsync() => asyncState;
''');
    await buildLibrary(
      library: input.uri,
      output: Directory('${directory.path}/module'),
      packagesPath: _packages,
    );
    await File('${directory.path}/check.mjs').writeAsString(r'''
import assert from 'node:assert/strict';
import {runInNewContext} from 'node:vm';
import * as api from './module/module.wasm';
const turn = () => new Promise(resolve => setImmediate(resolve));
const callback = value => value + 2;
assert.equal(api.store(callback), 1);
await turn(); global.gc(); api.collect(1);
assert.equal(api.invoke(3), 5);
assert.equal(api.remove(callback), true, 'a later export reuses the same Dart adapter');
assert.equal(api.remove(callback), false);
assert.equal(await api.timer(callback), 6);
api.remember(callback);
for (let i = 0; i < 80 && api.alive(); i++) {
  await turn(); global.gc(); api.collect(i);
}
assert.equal(api.alive(), false, 'a live JS callback must not pin its Dart adapter');
assert.equal(callback(3), 5);
assert.equal(await api.asyncUse(async value => value + 3), 7);
assert.deepEqual(await api.asyncList(async values => values.map(value => value + 3)), [4, 5]);
assert.equal(await api.asyncVoid(async () => 9), undefined);
for (const value of [3, {then(resolve) { resolve(3); }}, null, undefined]) {
  assert.equal(api.catchStart(() => value), true);
  await assert.rejects(api.asyncUse(() => value), /expected a Promise/);
  await assert.rejects(api.asyncVoid(() => value), /expected a Promise/);
}
class SubPromise extends Promise {}
assert.equal(await api.asyncUse(() => SubPromise.resolve(8)), 8);
assert.equal(await api.asyncUse(() => runInNewContext('Promise.resolve(9)')), 9);
const ownThen = Promise.resolve(10);
Object.defineProperty(ownThen, 'then', {get() { throw Error('own then must not be read'); }});
assert.equal(await api.asyncUse(() => ownThen), 10);
for (const exact of [null, undefined, Symbol('exact')]) {
  assert.equal(api.catchStart(() => { throw exact; }), true);
  await assert.rejects(api.asyncUse(() => { throw exact; }), error => error === exact);
  await assert.rejects(api.asyncUse(() => Promise.reject(exact)), error => error === exact);
  const species = Promise.resolve(11);
  Object.defineProperty(species, 'constructor', {get() { throw exact; }});
  assert.equal(api.catchStart(() => species), true);
  await assert.rejects(api.asyncUse(() => species), error => error === exact);
}
await assert.rejects(api.asyncUse(async () => 'wrong'), TypeError);
let finish;
const pending = api.asyncUse(() => new Promise(resolve => { finish = resolve; }));
for (let i = 0; i < 4; i++) { await turn(); global.gc(); api.collect(i); }
finish(12);
assert.equal(await pending, 12);
assert.equal(await api.asyncUse(async () => 13), 13);
const apply = Reflect.apply;
const methods = [
  [WeakMap.prototype, 'get'], [WeakMap.prototype, 'set'],
  [Map.prototype, 'get'], [Map.prototype, 'set'], [WeakRef.prototype, 'deref'],
];
const saved = methods.map(([prototype, name]) => prototype[name]);
try {
  for (const [prototype, name] of methods) prototype[name] = () => { throw Error('replaced ' + name); };
  assert.equal(api.store(callback), 1);
  assert.equal(api.store(callback), 2);
  assert.equal(api.remove(callback), true);
  assert.equal(api.remove(callback), true);
} finally {
  methods.forEach(([prototype, name], index) => { prototype[name] = saved[index]; });
}
const setAdd = Set.prototype.add;
const setDelete = Set.prototype.delete;
const uncaught = [];
const onUncaught = error => uncaught.push(error);
process.on('uncaughtException', onUncaught);
try {
  for (const [name, original] of [['add', setAdd], ['delete', setDelete]]) {
    Set.prototype[name] = function(value) {
      if (value && typeof value === 'object' && 'roots' in value && 'callback' in value) {
        throw Error('replaced pending callback ' + name);
      }
      return apply(original, this, [value]);
    };
  }
  api.startAsync(async value => value + 10);
  for (let i = 0; i < 10 && api.readAsync() === 0; i++) await turn();
  assert.equal(api.readAsync(), 14);
  await turn();
} finally {
  Set.prototype.add = setAdd;
  Set.prototype.delete = setDelete;
  process.off('uncaughtException', onUncaught);
}
assert.deepEqual(uncaught, []);
for (let i = 0; i < 80 && api.alive(); i++) {
  await turn(); global.gc(); api.collect(i);
}
assert.equal(api.alive(), false, 'settled callback roots clear after prototype mutation');
''');
    final execution = await Process.run('node', [
      '--expose-gc',
      'check.mjs',
    ], workingDirectory: directory.path);
    expect(
      execution.exitCode,
      0,
      reason: '${execution.stdout}${execution.stderr}',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}
