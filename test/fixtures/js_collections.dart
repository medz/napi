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

typedef NestedHandles = ({
  List<JsArray<int>?> arrays,
  Map<String, JsMap<String, int?>?> maps,
  Dictionary<JsArray<int>> dictionaries,
});

@NAPI()
NestedHandles nested(NestedHandles value) {
  _array = value.arrays.first;
  _map = value.maps['first'];
  _entered++;
  return value;
}

@NAPI()
int? nestedAccess(NestedHandles value, bool mutate) {
  final array = value.arrays.first!;
  final map = value.maps['first']!;
  if (mutate) {
    array.set(0, 42);
    map.set('key', 43);
  }
  return array.get(0);
}

@NAPI()
Future<NestedHandles> nestedLater(NestedHandles value) async => value;
@NAPI()
Stream<NestedHandles> nestedEvents(NestedHandles value) => Stream.value(value);
@NAPI()
List<JsArray<T>> nestedPayloads<T>(List<JsArray<T>> value) => value;

@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new')
class NestedValue {
  final JsArray<int> array;
  final JsMap<String, int?> map;
  NestedValue(this.array, this.map) {
    _array = array;
    _map = map;
  }
}

@NAPI()
NestedValue nestedValue(NestedValue value, List<int> later) {
  _entered++;
  return value;
}

@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new')
class NestedCapture {
  final JsArray<int> trigger;
  NestedCapture(this.trigger) {
    trigger.get(0);
  }
}

@NAPI()
List<JsArray<int>> nestedCaptured(
  ({NestedCapture first, JsArray<int> last}) value,
) => [value.last];

String _nestedOrder = '';

@NAPI(classPolicy: ClassPolicy.value)
class NestedOutput {
  final JsArray<int> _value;
  final bool _fail;
  NestedOutput(this._value, this._fail);
  JsArray<int> get first {
    _nestedOrder += 'first;';
    return _value;
  }

  int get last {
    _nestedOrder += 'last;';
    if (_fail) throw StateError('later nested getter');
    return 1;
  }
}

@NAPI()
NestedOutput nestedFake(bool fail) {
  _nestedOrder = '';
  return NestedOutput(_FakeArray(), fail);
}

@NAPI(bigint: true)
NestedOutput nestedWrongPolicy(bool fail) {
  _nestedOrder = '';
  return NestedOutput(_array!, fail);
}

@NAPI()
String nestedOrder() => _nestedOrder;

@NAPI()
class NestedArrays<T> {
  final JsArray<JsArray<T>?> _source;
  JsArray<T>? _saved;
  NestedArrays(this._source);
  JsArray<JsArray<T>?> source() => _source;
  bool load(int index) {
    _saved = _source.get(index);
    return _saved != null;
  }

  JsArray<T>? saved() => _saved;
  bool same(JsArray<T> value) => identical(_saved, value);
  T? read(int index) => _saved!.get(index);
  void put(int index, T value) => _saved!.set(index, value);
  void replace(int index) => _source.set(index, _saved);
  Future<T?> delayedRead(int index) async {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return _saved!.get(index);
  }
}

@NAPI()
class NestedMaps<T> {
  final JsMap<JsArray<int>, JsMap<String, T?>> _source;
  Iterator<(JsArray<int>, JsMap<String, T?>)>? _iterator;
  (JsArray<int>, JsMap<String, T?>)? _entry;
  NestedMaps(this._source);
  JsMap<JsArray<int>, JsMap<String, T?>> source() => _source;
  void start() => _iterator = _source.entries.iterator;
  bool next() {
    if (!_iterator!.moveNext()) {
      _entry = null;
      return false;
    }
    _entry = _iterator!.current;
    return true;
  }

  JsArray<int>? key() => _entry?.$1;
  JsMap<String, T?>? value() => _entry?.$2;
  bool sameKey(JsArray<int> key) => identical(_entry!.$1, key);
  bool sameValue(JsMap<String, T?> value) => identical(_entry!.$2, value);
  int? readKey(int index) => _entry!.$1.get(index);
  void writeKey(int index, int value) => _entry!.$1.set(index, value);
  T? read(String key) => _entry!.$2.get(key);
  void put(String key, T? value) => _entry!.$2.set(key, value);
  void putEntry(JsArray<int> key, JsMap<String, T?> value) =>
      _source.set(key, value);
}

JsArray<int>? _nestedNumber;

@NAPI()
JsArray<JsArray<int>> nestedNumbers(JsArray<JsArray<int>> value) {
  final inner = _nestedNumber = value.get(0)!;
  inner.set(0, inner.get(0)!);
  return value;
}

@NAPI(bigint: true)
JsArray<JsArray<int>> nestedInt64(JsArray<JsArray<int>> value) {
  final inner = value.get(0)!;
  inner.set(0, inner.get(0)!);
  return value;
}

@NAPI(bigint: true)
void nestedWriteWrongPolicy(JsArray<JsArray<int>> value) =>
    value.set(0, _nestedNumber!);

@NAPI()
void nestedFakeWrite(JsArray<JsArray<int>> value) => value.set(0, _FakeArray());

@NAPI()
JsArray<T>? nestedCallback<T>(
  JsArray<JsArray<T>?> Function(JsArray<JsArray<T>?>) callback,
  JsArray<JsArray<T>?> value,
) => callback(value).get(0);

@NAPI()
Future<JsArray<T>?> nestedAsyncCallback<T>(
  Future<JsArray<JsArray<T>?>> Function(JsArray<JsArray<T>?>) callback,
  JsArray<JsArray<T>?> value,
) async => (await callback(value)).get(0);

@NAPI()
class RefItem {
  int value;
  RefItem(this.value);
}

@NAPI()
class RefChild extends RefItem {
  RefChild(super.value);
}

@NAPI()
class OtherItem {
  int value;
  OtherItem(this.value);
}

@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class ResourceItem extends RefItem {
  ResourceItem(super.value);
  void close() {}
}

@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'release')
class OtherResource {
  OtherResource();
  void release() {}
}

class _ConflictingResource extends RefItem
    implements ResourceItem, OtherResource {
  _ConflictingResource() : super(100);
  @override
  void close() {}
  @override
  void release() {}
}

@NAPI()
void writeReferenceResource(JsArray<RefItem?> value) =>
    value.set(0, ResourceItem(101));

@NAPI()
void writeConflictingResource(JsArray<RefItem?> value) =>
    value.set(0, _ConflictingResource());

@NAPI()
class ReferenceCollections {
  final JsArray<RefItem?> _array;
  final JsMap<RefItem, RefItem?> _map;
  RefItem? _saved;
  Iterator<(RefItem, RefItem?)>? _iterator;
  (RefItem, RefItem?)? _entry;
  ReferenceCollections(this._array, this._map);
  JsArray<RefItem?> array() => _array;
  JsMap<RefItem, RefItem?> map() => _map;
  RefItem? read(int index) => _array.get(index);
  void write(int index, RefItem? value) => _array.set(index, value);
  void save(int index) => _saved = _array.get(index);
  RefItem? saved() => _saved;
  bool has(RefItem key) => _map.has(key);
  RefItem? get(RefItem key) => _map.get(key);
  void put(RefItem key, RefItem? value) => _map.set(key, value);
  bool remove(RefItem key) => _map.delete(key);
  void start() => _iterator = _map.entries.iterator;
  bool next() {
    if (!_iterator!.moveNext()) {
      _entry = null;
      return false;
    }
    _entry = _iterator!.current;
    return true;
  }

  RefItem? key() => _entry?.$1;
  RefItem? value() => _entry?.$2;
  Future<RefItem?> delayedRead(int index) async {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return _array.get(index);
  }

  Future<RefItem?> captured(int index) async {
    final value = _array.get(index);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return value;
  }

  void writeResource(int index) => _array.set(index, ResourceItem(97));
  void putResourceKey() => _map.set(ResourceItem(98), null);
  void putResourceValue(RefItem key) => _map.set(key, ResourceItem(99));
}

@NAPI()
RefItem? nestedReference(JsArray<JsArray<RefItem?>> value) =>
    value.get(0)!.get(0);

@NAPI()
RefItem? referenceCallback(
  JsArray<RefItem?> Function(JsArray<RefItem?>) callback,
  JsArray<RefItem?> value,
) => callback(value).get(0);

@NAPI()
class RefBox<T> {
  final T value;
  RefBox(this.value);
}

@NAPI()
RefBox<T>? referenceBox<T>(JsArray<RefBox<T>> value) => value.get(0);

class ConcreteItem<T> {
  final T value;
  ConcreteItem(this.value);
}

@NAPI()
typedef IntItem = ConcreteItem<int>;

@NAPI()
typedef TextItem = ConcreteItem<String>;

@NAPI()
TextItem? concreteReference(JsMap<IntItem, TextItem> value, IntItem key) =>
    value.get(key);
