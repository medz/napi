import 'dart:io';

import 'package:napi/src/build/build.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Wasm streams preserve snapshots, raw values and delivery lifetimes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'napi-wasm-stream-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final input = await File('${directory.path}/business.dart')
          .writeAsString('''
import 'dart:async';
import 'package:napi/napi.dart';
int cleaned = 0;
int cancelled = 0;
List<int> allocation = [];
StreamController<int>? held;
@NAPI() Stream<int> numbers(int start) async* { yield start; yield start + 1; }
@NAPI() Stream<T> payloads<T>(T first, T second) async* { yield first; yield second; }
@NAPI() Stream<void> voids() async* { yield null; }
@NAPI() Stream<int> failing(int Function() callback) async* { yield 1; yield callback(); }
@NAPI() Stream<int> sourceRangeError() => Stream.error(RangeError('source-range'));
@NAPI() Stream<int> overflow() {
  late StreamController<int> controller;
  controller = StreamController<int>.broadcast(sync: true, onListen: () {
    scheduleMicrotask(() {
      for (var i = 0; i < 66; i++) { controller.add(i); }
      controller.close();
    });
  });
  return controller.stream;
}
@NAPI() Stream<List<int>> snapshots() {
  late StreamController<List<int>> controller;
  controller = StreamController(sync: true, onListen: () {
    scheduleMicrotask(() {
      final value = [1];
      controller.add(value);
      value[0] = 2;
      controller.add(value);
      value[0] = 3;
      controller.close();
    });
  });
  return controller.stream;
}
@NAPI() Stream<int> retain<T>(T value) {
  held = StreamController<int>();
  return held!.stream;
}
@NAPI() int pressure(int seed) {
  allocation = List<int>.generate(100000, (i) => seed + i);
  return allocation.last;
}
@NAPI() int cleanupCount() => cleaned;
@NAPI() int cancelCount() => cancelled;
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Resource {
  Resource();
  Stream<int> watch() => StreamController<int>(onCancel: () async {
    await Future<void>.delayed(Duration(milliseconds: 1));
    cancelled++;
  }).stream;
  void close() { cleaned++; }
}
''');
      await buildLibrary(
        library: input.uri,
        output: Directory('${directory.path}/module'),
        packagesPath: File('.dart_tool/package_config.json').absolute.path,
      );
      await File('${directory.path}/check.mjs').writeAsString(r'''
import assert from 'node:assert/strict';
import * as api from './module/module.wasm';
const turn = () => new Promise(resolve => setImmediate(resolve));
const iterator = api.numbers(4);
assert.equal(iterator[Symbol.asyncIterator](), iterator);
const reads = [iterator.next(), iterator.next(), iterator.next()];
assert(reads.every(value => value instanceof Promise));
const results = await Promise.all(reads);
assert.deepEqual(results.map(value => [value.value, value.done]), [[4, false], [5, false], [undefined, true]]);
assert(results.every(value => Object.getPrototypeOf(value) === null));
assert.equal((await iterator.return()).done, true);
let thenReads = 0;
const payload = {get then() { thenReads++; throw Error('payload then'); }};
const raw = api.payloads(payload, undefined);
assert.equal((await raw.next()).value, payload);
assert.equal((await raw.next()).value, undefined);
assert.equal((await raw.next()).done, true);
assert.equal(thenReads, 0);
const nullish = api.payloads(null, undefined);
const inherited = Object.getOwnPropertyDescriptor(Object.prototype, 'then');
try {
  Object.defineProperty(Object.prototype, 'then', {configurable: true, get() { throw Error('inherited then'); }});
  assert.equal((await nullish.next()).value, null);
  assert.equal((await nullish.next()).value, undefined);
  assert.equal((await nullish.next()).done, true);
} finally {
  if (inherited === undefined) delete Object.prototype.then;
  else Object.defineProperty(Object.prototype, 'then', inherited);
}
const empty = api.voids();
assert.equal((await empty.next()).value, undefined);
assert.equal((await empty.next()).done, true);
for (const exact of [null, undefined, Symbol('exact')]) {
  const failed = api.failing(() => { throw exact; });
  assert.equal((await failed.next()).value, 1);
  await assert.rejects(failed.next(), error => error === exact);
  assert.equal((await failed.next()).done, true);
}
const overflow = api.overflow();
for (let i = 0; i <= 64; i++) assert.equal((await overflow.next()).value, i);
await assert.rejects(overflow.next(), error => error instanceof RangeError &&
  error.message === 'Stream buffer limit (64) exceeded.' && typeof error.dartStack === 'string');
assert.equal((await overflow.next()).done, true);
await assert.rejects(api.sourceRangeError().next(), error => error instanceof Error &&
  !(error instanceof RangeError) && error.message.includes('source-range'));
const snapshots = api.snapshots();
const one = snapshots.next(), two = snapshots.next();
assert.deepEqual((await one).value, [1]);
assert.deepEqual((await two).value, [2]);
assert.equal((await snapshots.next()).done, true);
const resource = new api.Resource();
const watched = resource.watch();
const apply = Reflect.apply;
const setAdd = Set.prototype.add, setDelete = Set.prototype.delete;
try {
  for (const [name, original] of [['add', setAdd], ['delete', setDelete]]) {
    Set.prototype[name] = function(value) {
      if (value && Object.hasOwn(value, 'streamFailure')) throw Error('replaced Promise registry ' + name);
      return apply(original, this, [value]);
    };
  }
  const pending = watched.next();
  const closed = resource.close();
  assert(closed instanceof Promise);
  assert.equal(api.cleanupCount(), 0);
  assert.equal((await pending).done, true);
  await closed;
} finally {
  Set.prototype.add = setAdd;
  Set.prototype.delete = setDelete;
}
assert.equal(api.cancelCount(), 1);
assert.equal(api.cleanupCount(), 1);
assert.equal((await watched.return()).done, true);
let held;
const weak = (() => {
  const value = {retained: true};
  held = api.retain(value);
  return new WeakRef(value);
})();
const waiting = held.next();
for (let i = 0; i < 4; i++) {
  await turn(); global.gc(); api.pressure(i); await turn();
  assert.notEqual(weak.deref(), undefined);
}
assert.equal((await held.return()).done, true);
assert.equal((await waiting).done, true);
for (let i = 0; i < 80 && weak.deref() !== undefined; i++) {
  await turn(); global.gc(); api.pressure(i);
}
assert.equal(weak.deref(), undefined, 'closed facade clears its original input roots');
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
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
