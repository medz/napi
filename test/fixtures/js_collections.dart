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

@NAPI()
class ArrayPayloads<T> {
  JsArray<T>? _source;
  WeakReference<JsArray<T>>? _weak;
  T? _saved;
  ArrayPayloads(JsArray<T> source) {
    remember(source);
  }
  void remember(JsArray<T> source) {
    _source = source;
    _weak = WeakReference(source);
  }

  JsArray<T> source() => _source!;
  bool same(JsArray<T> source) => identical(_weak?.target, source);
  bool alive() => _weak?.target != null;
  bool load(int index) {
    _saved = _source!.get(index);
    return _saved != null;
  }

  T? saved() => _saved;
  void put(int index, T value) => _source!.set(index, value);
  void dropSource() => _source = null;
  void clearSaved() => _saved = null;
  Future<T?> captured(int milliseconds) async {
    final value = _source!.get(0);
    await Future<void>.delayed(Duration(milliseconds: milliseconds));
    return value;
  }

  Future<JsArray<T>> later() async => _source!;
  Stream<T?> events() => Stream<T?>.value(_saved);
  Stream<JsArray<T>> sources() => Stream<JsArray<T>>.value(_source!);
}

@NAPI()
class MapPayloads<K, V> {
  final JsMap<K, V> _source;
  V? _saved;
  Iterator<(K, V)>? _iterator;
  (K, V)? _entry;
  MapPayloads(this._source);
  JsMap<K, V> source() => _source;
  bool has(K key) => _source.has(key);
  V? get(K key) => _source.get(key);
  void put(K key, V value) => _source.set(key, value);
  bool remove(K key) => _source.delete(key);
  bool load(K key) {
    _saved = _source.get(key);
    return _saved != null;
  }

  V? saved() => _saved;
  void clearSaved() => _saved = null;
  void start() => _iterator = _source.entries.iterator;
  bool next() {
    if (!_iterator!.moveNext()) {
      _entry = null;
      return false;
    }
    _entry = _iterator!.current;
    return true;
  }

  K? key() => _entry?.$1;
  V? value() => _entry?.$2;
  void dropIterator() {
    _iterator = null;
    _entry = null;
  }
}

@NAPI()
bool renamedPolicy<A, B>(JsArray<A> a, JsArray<B> b) => identical(a, b);
@NAPI()
bool numberPolicy<T>(JsArray<int> a, JsArray<T> b) => identical(a, b);
@NAPI()
bool nullablePayload<T>(JsArray<T?> source) {
  source.set(1, null);
  return source.get(0) != null;
}

@NAPI()
bool nullableMapPayload<K, V>(JsMap<K?, V?> source) {
  source.set(null, null);
  return source.has(null) && source.get(null) != null;
}

@NAPI()
T? stringPayload<T>(JsMap<String, T> source, String key) => source.get(key);
@NAPI()
int? keyedScalar<K>(JsMap<K, int> source, K key) => source.get(key);
@NAPI()
T firstPayload<T>(JsMap<String, T> source) => source.entries.first.$2;
@NAPI()
int firstScalar<K>(JsMap<K, int> source) => source.entries.first.$2;
