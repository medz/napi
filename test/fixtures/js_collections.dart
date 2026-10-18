import 'dart:async';

import 'package:napi/napi.dart';

JsArray<int>? _array;
JsMap<String, int?>? _map;
WeakReference<JsArray<int>>? _weakArray;
WeakReference<JsMap<String, int?>>? _weakMap;
Iterator<(String, int?)>? _iterator;
List<int> _pressure = [];
int _entered = 0;
Completer<void>? _gate;

@NAPI()
JsArray<int> remember(JsArray<int> value) {
  _array = value;
  _weakArray = WeakReference(value);
  return value;
}

@NAPI()
bool same(JsArray<int> value) => identical(_array, value);
@NAPI()
bool alive() => _weakArray?.target != null;
@NAPI()
int drop() {
  _array = null;
  _map = null;
  _iterator = null;
  return 0;
}

@NAPI()
int pressure(int seed) {
  _pressure = List.generate(500000, (i) => i + seed);
  return _pressure.last;
}

@NAPI()
int length() => _array!.length;
@NAPI()
int? read(int index) => _array!.get(index);
@NAPI()
int write(int index, int value) {
  _array!.set(index, value);
  return value;
}

@NAPI()
int caught(int index) {
  try {
    _array!.get(index);
    return 0;
  } catch (_) {
    return 1;
  }
}

@NAPI()
Future<int?> delayedRead(int index) async {
  await Future<void>.delayed(const Duration(milliseconds: 1));
  return _array!.get(index);
}

@NAPI()
JsArray<int>? optional([JsArray<int>? value]) => value;
@NAPI()
JsArray<int>? named({JsArray<int>? value}) => value;
@NAPI()
JsArray<int?> nullable(JsArray<int?> value) {
  value.set(0, value.get(0));
  return value;
}

@NAPI()
JsArray<bool> booleans(JsArray<bool> value) {
  value.set(0, value.get(0)!);
  return value;
}

@NAPI(bigint: true)
JsArray<bool> bigBooleans(JsArray<bool> value) {
  value.set(0, value.get(0)!);
  return value;
}

@NAPI()
JsArray<String> strings(JsArray<String> value) {
  value.set(0, value.get(0)!);
  return value;
}

@NAPI()
JsArray<double> doubles(JsArray<double> value) {
  value.set(0, value.get(0)!);
  return value;
}

@NAPI(bigint: true)
JsArray<int> int64(JsArray<int> value) {
  value.set(0, value.get(0)!);
  return value;
}

@NAPI()
JsArray<BigInt> bigints(JsArray<BigInt> value) {
  value.set(0, value.get(0)!);
  return value;
}

@NAPI()
int partial(JsArray<int> value, bool valid) {
  _entered++;
  return value.length;
}

@NAPI()
int entered() => _entered;
@NAPI()
Future<JsArray<int>> later(JsArray<int> value) async {
  await Future<void>.delayed(const Duration(milliseconds: 5));
  return value;
}

@NAPI()
Future<JsArray<int>> hold(JsArray<int> value) async {
  final gate = _gate = Completer<void>();
  await gate.future;
  return value;
}

@NAPI()
int complete() {
  _gate!.complete();
  _gate = null;
  return 0;
}

@NAPI()
Stream<JsArray<int>> events(JsArray<int> value) async* {
  yield value;
  yield value;
}

@NAPI()
JsMap<String, int?> rememberMap(JsMap<String, int?> value) {
  _map = value;
  _weakMap = WeakReference(value);
  return value;
}

@NAPI()
bool sameMap(JsMap<String, int?> value) => identical(_weakMap?.target, value);
@NAPI()
bool mapAlive() => _weakMap?.target != null;
@NAPI()
int size() => _map!.size;
@NAPI()
bool has(String key) => _map!.has(key);
@NAPI()
int? get(String key) => _map!.get(key);
@NAPI()
int put(String key, int? value) {
  _map!.set(key, value);
  return 1;
}

@NAPI()
bool remove(String key) => _map!.delete(key);
@NAPI()
int clear() {
  _map!.clear();
  return 0;
}

@NAPI()
int iterate() {
  _iterator = _map!.entries.iterator;
  _map = null;
  return 0;
}

@NAPI()
String? next() {
  if (!_iterator!.moveNext()) return null;
  final (key, value) = _iterator!.current;
  return '$key:${value ?? "null"}';
}

@NAPI()
bool doubleKey(JsMap<double, String> value, double key) => value.has(key);
@NAPI(bigint: true)
bool intKey(JsMap<int, String> value, int key) => value.has(key);
@NAPI()
bool bigKey(JsMap<BigInt, String> value, BigInt key) => value.has(key);
@NAPI()
bool nullKey(JsMap<String?, bool> value) => value.has(null);
@NAPI()
Future<JsMap<String, int?>> laterMap(JsMap<String, int?> value) async => value;
@NAPI()
Stream<JsMap<String, int?>> mapEvents(JsMap<String, int?> value) =>
    Stream.value(value);
@NAPI()
List<int> copied(List<int> value) {
  value[0]++;
  return value;
}

class _FakeArray implements JsArray<int> {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

@NAPI()
JsArray<int> fake() => _FakeArray();
@NAPI(bigint: true)
JsArray<int> wrongPolicy() => _array!;

@NAPI()
class Holder {
  Holder(this.value);
  JsArray<int> value;
  int? read(int index) => value.get(index);
}

@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Owner {
  Owner();
  int closed = 0;
  Future<JsArray<int>> retain(JsArray<int> value) async {
    return await hold(value);
  }

  void close() {
    closed++;
  }
}
