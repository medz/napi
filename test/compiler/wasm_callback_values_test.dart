import 'dart:io';

import 'package:napi/src/build/build.dart';
import 'package:test/test.dart';

void main() {
  test('Wasm callbacks convert values and scope resource references', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'napi-wasm-callback-values-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final input = await File('${temporary.path}/business.dart')
        .writeAsString('''
import 'dart:async';
import 'package:napi/napi.dart';
@NAPI(classPolicy: ClassPolicy.value)
class Value { const Value({this.n = 3}); final int n; }
@NAPI(classPolicy: ClassPolicy.value)
class Parsed { Parsed(String source) : n = int.parse(source); final int n; }
@NAPI(classPolicy: ClassPolicy.value)
class Key {
  Key(this.n);
  final int n;
  @override bool operator ==(Object other) => other is Key && other.n == n;
  @override int get hashCode => n;
}
@NAPI() class Box { Box(this.n); final int n; }
int closed = 0;
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Resource {
  Resource(this.n);
  final int n;
  int startScalar(Future<void> Function() callback) { callback(); return n; }
  void close() { closed++; }
}
@NAPI() int closedCount() => closed;
@NAPI() int value(Value Function(Value) callback) => callback(const Value()).n;
@NAPI() int parsed(Parsed Function(Parsed) callback) => callback(Parsed('7')).n;
@NAPI() int keyMap(Map<Key, int> Function() callback) => callback().length;
@NAPI() Future<int> laterKeyMap(Future<Map<Key, int>> Function() callback) async => (await callback()).length;
@NAPI() int containers(
  (Map<String, List<Value?>>, Dictionary<int>) Function(Map<String, List<Value?>>, Dictionary<int>) callback,
) {
  final result = callback({'a': [const Value(), null]}, Dictionary({'x': 5}));
  return result.\$1['a']!.first!.n + result.\$2['x']!;
}
@NAPI() Box reference(Box Function(Box) callback) => callback(Box(7));
@NAPI() Future<int> resource(Future<Resource> Function(Resource) callback) async {
  final source = Resource(9);
  final result = await callback(source);
  return result.n;
}
int started = 0;
@NAPI() int start(Future<Resource> Function(Resource) callback) {
  callback(Resource(13)).then((value) { started = value.n; });
  return 0;
}
@NAPI() int startedState() => started;
Future<Resource> Function()? stored;
@NAPI() int store(Future<Resource> Function() callback) { stored = callback; return 0; }
@NAPI() Future<int> invokeStored() async => (await stored!()).n;
@NAPI() int clearStored() { stored = null; return 0; }
int detached = 0;
@NAPI() int queue(Resource Function() callback) {
  detached = 0;
  Timer.run(() { try { callback(); detached = -1; } catch (_) { detached = 1; } });
  return 0;
}
@NAPI() int detachedState() => detached;
@NAPI() T opaque<T>(T Function(T) callback, T value) => callback(value);
@NAPI() Future<T> later<T>(Future<T> Function(T) callback, T value) => callback(value);
@NAPI() Dictionary<T?> dictionary<T>(Dictionary<T?> Function(Dictionary<T?>) callback, T value) =>
    callback(Dictionary({'value': value, 'null': null}));
''');
    await buildLibrary(
      library: input.uri,
      output: Directory('${temporary.path}/module'),
      packagesPath: File('.dart_tool/package_config.json').absolute.path,
    );
    await File('${temporary.path}/check.mjs').writeAsString(r'''
import assert from 'node:assert/strict';
import * as api from './module/module.wasm';
const turn = () => new Promise(resolve => setImmediate(resolve));
assert.equal(api.value(value => { assert.deepEqual(value, {n: 3}); return {}; }), 3);
assert.equal(api.parsed(value => { assert.deepEqual(value, {n: 7}); return {source: '9'}; }), 9);
assert.throws(() => api.parsed(value => value), TypeError);
const duplicateKeys = () => new Map([[{n: 1}, 1], [{n: 1}, 2]]);
assert.throws(() => api.keyMap(duplicateKeys), TypeError);
await assert.rejects(api.laterKeyMap(async () => duplicateKeys()), TypeError);
assert.equal(api.containers((map, dictionary) => {
  assert(map instanceof Map);
  assert.deepEqual(map.get('a'), [{n: 3}, null]);
  assert.equal(Object.getPrototypeOf(dictionary), null);
  assert.equal(dictionary.x, 5);
  return {$1: new Map([['a', [{n: 4}, null]]]), $2: {x: 6}};
}), 10);
let box;
assert.equal(api.reference(value => { box = value; return value; }), box);
assert(box instanceof api.Box);
assert.throws(() => api.reference(() => ({n: 7})), TypeError);
let closing, resource, finish;
const pending = api.resource(value => {
  resource = value;
  closing = value.close();
  return new Promise(resolve => { finish = resolve; });
});
assert(resource instanceof api.Resource);
await turn();
assert.equal(api.closedCount(), 0, 'callback argument lease delays cleanup');
finish(resource);
assert.equal(await pending, 9);
await closing;
assert.equal(api.closedCount(), 1);
let completeStarted, startedResource, startedClose;
api.start(value => {
  startedResource = value;
  startedClose = value.close();
  return new Promise(resolve => { completeStarted = resolve; });
});
await turn();
assert.equal(api.closedCount(), 1, 'a started Future callback retains its operation after a synchronous export');
completeStarted(startedResource);
for (let i = 0; i < 20 && api.startedState() === 0; i++) await turn();
assert.equal(api.startedState(), 13);
await startedClose;
assert.equal(api.closedCount(), 2);
const returned = new api.Resource(11);
api.store(async () => returned);
assert.equal(await api.invokeStored(), 11, 'later scalar export supplies the callback operation');
api.clearStored();
api.queue(() => returned);
for (let i = 0; i < 20 && api.detachedState() === 0; i++) {
  await new Promise(resolve => setTimeout(resolve, 2));
}
assert.equal(api.detachedState(), 1, 'detached callback cannot admit a resource');
await returned.close();
const scalarOwner = new api.Resource(15);
let finishScalar, scalarClosed = false;
assert.equal(scalarOwner.startScalar(() => new Promise(resolve => { finishScalar = resolve; })), 15);
const scalarClose = scalarOwner.close().then(() => { scalarClosed = true; });
await turn();
assert.equal(scalarClosed, true, 'a scalar callback does not prolong an unrelated receiver lease');
finishScalar();
await scalarClose;
for (const value of [undefined, null, Symbol('opaque'), {then: 1}, () => 1]) {
  assert.equal(api.opaque(input => { assert.equal(input, value); return input; }, value), value);
  assert.equal(await api.later(async input => { assert.equal(input, value); return input; }, value), value);
  const dictionary = api.dictionary(input => {
    assert.equal(input.value, value); assert.equal(input.null, null);
    return input;
  }, value);
  assert.equal(dictionary.value, value);
  assert.equal(dictionary.null, null);
}
''');
    final execution = await Process.run('node', [
      'check.mjs',
    ], workingDirectory: temporary.path);
    expect(
      execution.exitCode,
      0,
      reason: '${execution.stdout}${execution.stderr}',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}
