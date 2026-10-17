import 'dart:io';

import 'package:napi/build.dart';
import 'package:test/test.dart';

const _source = r'''import 'dart:collection';
import 'package:napi/napi.dart';
int _reads = 0;
int _indices = 0;
const unsafe = 9007199254740992;
@NAPI() int reads() => _reads;
@NAPI() int resetReads() { _reads = 0; _indices = 0; return 0; }
@NAPI() int indices() => _indices;
@NAPI() int ping() => 42;
class BadList extends ListBase<int> {
  @override int get length { _reads++; throw StateError('late list length'); }
  @override set length(int value) => throw UnimplementedError();
  @override int operator [](int index) => 0;
  @override void operator []=(int index, int value) => throw UnimplementedError();
}
class BadMapLength extends MapBase<String, int> {
  @override int get length { _reads++; throw StateError('late map length'); }
  @override Iterable<String> get keys => const ['x'];
  @override int? operator [](Object? key) => 1;
  @override void operator []=(String key, int value) => throw UnimplementedError();
  @override void clear() => throw UnimplementedError();
  @override int? remove(Object? key) => throw UnimplementedError();
}
class BadEntries extends Iterable<MapEntry<String, int>> {
  @override Iterator<MapEntry<String, int>> get iterator {
    _reads++; throw StateError('late map iterator');
  }
}
class BadMapIterator extends BadMapLength {
  @override int get length => 1;
  @override Iterable<MapEntry<String, int>> get entries => BadEntries();
}
@NAPI() List<List<int>> listLateList() => [[unsafe], BadList()];
@NAPI() (int, List<int>) recordLateList() => (unsafe, BadList());
@NAPI() Map<String, List<int>> mapLateList() => {'first': [unsafe], 'late': BadList()};
@NAPI() List<Map<String, int>> listLateMapIterator() => [{'first': unsafe}, BadMapIterator()];
@NAPI() (int, Map<String, int>) recordLateMapIterator() => (unsafe, BadMapIterator());
@NAPI() Map<String, Map<String, int>> mapLateMapLength() => {'first': {'x': unsafe}, 'late': BadMapLength()};
@NAPI() Dictionary<Map<String, int>> dictionaryLateMapLength() => Dictionary({'first': {'x': unsafe}, 'late': BadMapLength()});
@NAPI() (int, List<int>) safeBeforeLateList() => (1, BadList());
@NAPI() List<int> unsafeOnly() => [unsafe];
@NAPI() class RefBase { RefBase(); }
@NAPI() class RefChild extends RefBase { RefChild(); }
@NAPI() class RefOther {}
class _Ambiguous extends RefBase implements RefOther {}
final _bad = _Ambiguous();
RefChild? _shared;
@NAPI() RefChild primeChild() => _shared ??= RefChild();
@NAPI() (RefBase, List<int>) brandLateList() => (_bad, BadList());
@NAPI() (RefBase, Map<String, int>) brandLateMapIterator() => (_bad, BadMapIterator());
@NAPI() RefBase brandOnly() => _bad;

class ReadList extends ListBase<int> {
  @override int get length { _reads++; return 1; }
  @override set length(int value) => throw UnimplementedError();
  @override int operator [](int index) { _indices++; return 3; }
  @override void operator []=(int index, int value) => throw UnimplementedError();
}
@NAPI() (int, List<int>) snapshotHostFailure() => (unsafe, ReadList());
@NAPI() (RefBase, List<int>) snapshotBrandFailure() => (_bad, ReadList());
@NAPI() (Map<double, int>, List<int>) mapCollision(bool throwing) =>
    ({double.nan: 1, double.nan: 2}, throwing ? BadList() : ReadList());
class DuplicateDictionary extends MapBase<String, List<int>> {
  @override int get length => 2;
  @override Iterable<MapEntry<String, List<int>>> get entries =>
      [MapEntry('same', BadList()), MapEntry('same', BadList())];
  @override Iterable<String> get keys => const ['same', 'same'];
  @override List<int>? operator [](Object? key) => null;
  @override void operator []=(String key, List<int> value) => throw UnimplementedError();
  @override void clear() => throw UnimplementedError();
  @override List<int>? remove(Object? key) => throw UnimplementedError();
}
@NAPI() (Dictionary<List<int>>, List<int>) dictionaryDupBeforeLater() =>
    (Dictionary(DuplicateDictionary()), BadList());
final _fresh = RefChild();
final _snapshotFresh = RefChild();
final _collisionFresh = RefChild();
@NAPI() (RefBase, List<int>) pendingRollback() => (_fresh, [unsafe]);
@NAPI() RefChild freshChild() => _fresh;
@NAPI() (RefBase, List<int>) snapshotFailure() => (_snapshotFresh, BadList());
@NAPI() RefChild snapshotChild() => _snapshotFresh;
@NAPI() (RefBase, Map<double, int>) collisionRollback() =>
    (_collisionFresh, {double.nan: 1, double.nan: 2});
@NAPI() RefChild collisionChild() => _collisionFresh;
@NAPI() List<int> largeOutput() => List.filled(10000, 1);
@NAPI() List<List<int>> budgetAfterUnsafe() => [[unsafe], List.filled(10000, 1)];
@NAPI() List<List<int>> echoLists(List<List<int>> value) => value;
@NAPI() (int, List<int>) healthy() => (1, [2]);
@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new')
class Cycle {
  Cycle({this.next});
  Cycle? next;
}
@NAPI() Cycle cycleOutput() { final value = Cycle(); value.next = value; return value; }

@NAPI() List<int?> nullableList() => [1, null];
@NAPI() Map<int?, RefBase?> nullableMap() => {null: null};
@NAPI() Dictionary<int?> nullableDictionary() => Dictionary({'a': null, 'b': 1});
@NAPI() (int?, RefBase?) nullableRecord() => (null, null);
@NAPI() (List<int>, int) recordLeafBudget() => (List.filled(9998, 1), 2);
@NAPI() (Map<int?, RefBase?>, List<int>) mapLeafBudget(int length) =>
    ({null: null}, List.filled(length, 1));
@NAPI() (Dictionary<int?>, List<int>) dictionaryLeafBudget(int length) =>
    (Dictionary({'a': null, 'b': null}), List.filled(length, 1));
''';

const _checks = r'''import assert from 'node:assert/strict';
import * as api from './@ENTRY@';
function fails(action, expected, reads, indices = 0) {
  api.resetReads();
  assert.throws(action, expected);
  assert.equal(api.reads(), reads);
  assert.equal(api.indices(), indices);
  assert.equal(api.ping(), 42);
  assert.deepEqual(api.healthy(), {$1: 1, $2: [2]});
}
const domain = text => error => error.constructor === Error && error.message.includes(text);
const child = api.primeChild();
for (const name of ['listLateList', 'recordLateList', 'mapLateList']) {
  fails(() => api[name](), domain('late list length'), 1);
}
for (const name of ['listLateMapIterator', 'recordLateMapIterator']) {
  fails(() => api[name](), domain('late map iterator'), 1);
}
for (const name of ['mapLateMapLength', 'dictionaryLateMapLength']) {
  fails(() => api[name](), domain('late map length'), 1);
}
fails(() => api.brandLateList(), domain('late list length'), 1);
fails(() => api.brandLateMapIterator(), domain('late map iterator'), 1);
// The three controls distinguish the later Dart error from host validation.
fails(() => api.safeBeforeLateList(), domain('late list length'), 1);
fails(() => api.unsafeOnly(), RangeError, 0);
fails(() => api.brandOnly(), TypeError, 0);
// A completed snapshot reaches each custom getter/index exactly once even
// when host scalar/ref checks reject a preceding field afterwards.
fails(() => api.snapshotHostFailure(), RangeError, 1, 1);
fails(() => api.snapshotBrandFailure(), TypeError, 1, 1);
assert.equal(api.primeChild(), child);
fails(() => api.mapCollision(true), domain('late list length'), 1);
fails(() => api.mapCollision(false), error => error instanceof TypeError &&
  error.message === 'mapCollision result.$1[1].key: duplicate converted Map key', 1, 1);
// Original duplicate String keys fail during the Dart raw-entry snapshot,
// before either the Dictionary's children or the later sibling is read.
fails(() => api.dictionaryDupBeforeLater(), error => error instanceof TypeError &&
  error.message === 'dictionaryDupBeforeLater result.$1["same"]: duplicate Dictionary key', 0);
fails(() => api.snapshotFailure(), domain('late list length'), 1);
assert(api.snapshotChild() instanceof api.RefChild);
fails(() => api.pendingRollback(), RangeError, 0);
const fresh = api.freshChild();
assert(fresh instanceof api.RefChild);
fails(() => api.collisionRollback(), error => error instanceof TypeError &&
  error.message === 'collisionRollback result.$2[1].key: duplicate converted Map key', 0);
assert(api.collisionChild() instanceof api.RefChild);
for (let i = 0; i < 3; i++) {
  global.gc();
  await new Promise(setImmediate);
}
assert.equal(api.freshChild(), fresh);
assert.equal(api.primeChild(), child);
fails(() => api.largeOutput(), error => error instanceof RangeError && error.message.includes('work limit (10000)'), 0);
fails(() => api.budgetAfterUnsafe(), error => error instanceof RangeError &&
  error.message === 'budgetAfterUnsafe result[1]: structural work limit (10000) exceeded', 0);
fails(() => api.deepOutput(), error => error instanceof RangeError && error.message.includes('depth limit (64)'), 0);
const cycle = [];
cycle.push(cycle);
fails(() => api.echoLists(cycle), error => error instanceof TypeError && error.message.includes('cyclic structural value'), 0);
fails(() => api.cycleOutput(), error => error instanceof TypeError && error.message.includes('cyclic structural value'), 0);
assert.deepEqual(api.nullableList(), [1, null]);
assert.equal(api.nullableMap().get(null), null);
assert.equal(api.nullableMap().size, 1);
const dictionary = api.nullableDictionary();
assert.equal(Object.getPrototypeOf(dictionary), null);
assert.deepEqual({...dictionary}, {a: null, b: 1});
assert.deepEqual(api.nullableRecord(), {$1: null, $2: null});
fails(() => api.recordLeafBudget(), error => error instanceof RangeError &&
  error.message === 'recordLeafBudget result.$2: structural work limit (10000) exceeded', 0);
assert.equal(api.mapLeafBudget(9995).$2.length, 9995);
fails(() => api.mapLeafBudget(9996), error => error instanceof RangeError &&
  error.message === 'mapLeafBudget result.$2: structural work limit (10000) exceeded', 0);
assert.equal(api.dictionaryLeafBudget(9995).$2.length, 9995);
fails(() => api.dictionaryLeafBudget(9996), error => error instanceof RangeError &&
  error.message === 'dictionaryLeafBudget result.$2: structural work limit (10000) exceeded', 0);
console.log('structural-output-order-ok');
''';

void main() {
  final packages = File('.dart_tool/package_config.json').absolute.path;
  final nativeRuntime = Platform.environment['NAPI_TEST_NATIVE_RUNTIME'];
  for (final target in BuildTarget.values) {
    test(
      '${target.name} structural outputs finish Dart snapshots before host checks',
      () async {
        final temporary = await Directory.systemTemp.createTemp(
          'napi-structural-output-',
        );
        final directory = Directory(await temporary.resolveSymbolicLinks());
        addTearDown(() => directory.delete(recursive: true));
        final deepType =
            '${List.filled(65, 'List<').join()}int${List.filled(65, '>').join()}';
        final deepValue =
            '${List.filled(65, '[').join()}1${List.filled(65, ']').join()}';
        final input = await File('${directory.path}/business.dart')
            .writeAsString(
              '$_source\n@NAPI() $deepType deepOutput() => $deepValue;\n',
            );
        final module = await buildLibrary(
          library: input.uri,
          output: Directory('${directory.path}/built'),
          packagesPath: packages,
          target: target,
          nativeRuntime: target == BuildTarget.native
              ? Directory(nativeRuntime!)
              : null,
        );
        final script = await File('${module.directory.path}/test.mjs')
            .writeAsString(
              _checks.replaceAll(
                '@ENTRY@',
                target == BuildTarget.wasm ? 'module.wasm' : 'module.mjs',
              ),
            );
        final result = await Process.run(
          Platform.environment['NODE'] ?? 'node',
          ['--expose-gc', script.path],
        );
        expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
        expect(result.stdout, contains('structural-output-order-ok'));
      },
      skip: target == BuildTarget.native && nativeRuntime == null
          ? 'Set NAPI_TEST_NATIVE_RUNTIME to a precompiled runtime bundle.'
          : false,
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}
