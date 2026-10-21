import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

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
  void close() {
    _collectionCleanups.update(value, (count) => count + 1, ifAbsent: () => 1);
    _collectionEvents.add('close:$value');
  }
}

final _collectionCleanups = <int, int>{};
final _collectionEvents = <String>[];
final _collectionGates = <int, Completer<void>>{};
List<int> _collectionTimer = [];

Future<void> _collectionGate(int token) =>
    (_collectionGates[token] = Completer<void>()).future;

@NAPI()
int collectionCleanups(int id) => _collectionCleanups[id] ?? 0;
@NAPI()
List<String> collectionEvents() => List.of(_collectionEvents);
@NAPI()
bool collectionWaiting(int token) => _collectionGates.containsKey(token);
@NAPI()
void collectionComplete(int token) =>
    _collectionGates.remove(token)!.complete();

@NAPI()
void collectionTimers(JsArray<ResourceItem> resources, JsArray<int> scalars) {
  _collectionTimer = [];
  Timer(const Duration(milliseconds: 1), () {
    try {
      resources.get(0);
      _collectionTimer.add(0);
    } catch (_) {
      _collectionTimer.add(1);
    }
    _collectionTimer.add(scalars.get(0)!);
  });
}

@NAPI()
List<int> collectionTimerResult() => List.of(_collectionTimer);

@NAPI()
class ResourceCollections {
  final JsArray<ResourceItem?> _array;
  final JsMap<ResourceItem, ResourceItem?> _map;
  Iterator<(ResourceItem, ResourceItem?)>? _iterator;
  (ResourceItem, ResourceItem?)? _entry;
  ResourceCollections(this._array, this._map);
  JsArray<ResourceItem?> array() => _array;
  JsMap<ResourceItem, ResourceItem?> map() => _map;
  ResourceItem? read(int index) => _array.get(index);
  void write(int index, ResourceItem? value) => _array.set(index, value);
  bool has(ResourceItem key) => _map.has(key);
  ResourceItem? get(ResourceItem key) => _map.get(key);
  void put(ResourceItem key, ResourceItem? value) => _map.set(key, value);
  void start() => _iterator = _map.entries.iterator;
  bool next() {
    if (!_iterator!.moveNext()) {
      _entry = null;
      return false;
    }
    _entry = _iterator!.current;
    return true;
  }

  ResourceItem? key() => _entry?.$1;
  ResourceItem? value() => _entry?.$2;
  Future<int> hold(int token, bool afterAwait) async {
    if (afterAwait) await _collectionGate(token + 1000);
    final first = _array.get(0)!;
    await _collectionGate(token);
    final last = _array.get(0)!;
    if (!identical(first, last)) throw StateError('resource identity changed');
    return last.value;
  }

  Future<T> result<T>(int token, T value) async {
    _array.get(0);
    await _collectionGate(token);
    return value;
  }

  Stream<int> watch(int token) {
    late StreamController<int> source;
    source = StreamController<int>(
      sync: true,
      onListen: () async {
        try {
          await _collectionGate(token);
          final value = _array.get(0)!;
          _collectionEvents.add('read:$token');
          source.add(value.value);
        } catch (error, stack) {
          source.addError(error, stack);
        }
      },
      onCancel: () async {
        _collectionEvents.add('cancel:$token');
        await _collectionGate(-token);
        _collectionEvents.add('cancelled:$token');
      },
    );
    return source.stream;
  }
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

@NAPI()
class BinaryCollections {
  final JsArray<Uint8List?> _array;
  final JsMap<String, ByteBuffer?> _map;
  Uint8List? _bytes;
  ByteBuffer? _buffer;
  BinaryCollections(this._array, this._map);
  JsArray<Uint8List?> array() => _array;
  JsMap<String, ByteBuffer?> map() => _map;
  Uint8List? read(int index) => _array.get(index);
  void save(int index) => _bytes = _array.get(index);
  Uint8List? saved() => _bytes;
  void change(int value) => _bytes![0] = value;
  void write(int index, Uint8List? value) => _array.set(index, value);
  void writeSaved(int index) => _array.set(index, _bytes);
  void writeWindow(int index) {
    final backing = Uint8List.fromList([90, 1, 2, 91]);
    _bytes = Uint8List.sublistView(backing, 1, 3);
    _array.set(index, _bytes);
    backing[1] = 99;
  }

  ByteBuffer? get(String key) => _map.get(key);
  void saveBuffer(String key) => _buffer = _map.get(key);
  ByteBuffer? savedBuffer() => _buffer;
  void changeBuffer(int value) => _buffer!.asUint8List()[0] = value;
  void put(String key, ByteBuffer? value) => _map.set(key, value);
  void putSaved(String key) => _map.set(key, _buffer);
  void putWindow(String key) {
    final backing = Uint8List.fromList([90, 1, 2, 91]);
    _buffer = Uint8List.sublistView(backing, 1, 3).buffer;
    _map.set(key, _buffer);
    backing[0] = 99;
  }

  Future<Uint8List?> captured(int index) async {
    final value = _array.get(index);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return value;
  }
}

@NAPI()
Uint8List? nestedBinary(JsArray<JsArray<Uint8List>> value) =>
    value.get(0)!.get(0);

@NAPI()
ByteBuffer? nestedBuffer(JsArray<JsMap<String, ByteBuffer?>> value) =>
    value.get(0)!.get('key');

@NAPI()
Future<Uint8List?> binaryCallback(
  Future<JsArray<Uint8List?>> Function(JsArray<Uint8List?>) callback,
  JsArray<Uint8List?> value,
) async => (await callback(value)).get(0);

@NAPI()
bool copiedBinaryKey(JsMap<Uint8List, ByteBuffer> value) {
  final (key, buffer) = value.entries.first;
  if (value.has(key) || value.get(key) != null || value.delete(key)) {
    return false;
  }
  key[0] = 7;
  buffer.asUint8List()[0] = 8;
  value.set(key, buffer);
  key[0] = 9;
  buffer.asUint8List()[0] = 10;
  return true;
}

@NAPI()
bool nullableBinaryKey(JsMap<Uint8List?, bool> value) {
  value.set(null, true);
  return value.has(null) && value.get(null) == true;
}

@NAPI()
class SharedByteCollections {
  final JsArray<SharedBytes?> _array;
  final JsMap<SharedBytes, SharedBytes> _map;
  SharedBytes? _saved;
  (SharedBytes, SharedBytes)? _entry;
  SharedByteCollections(this._array, this._map);
  JsArray<SharedBytes?> array() => _array;
  JsMap<SharedBytes, SharedBytes> map() => _map;
  SharedBytes? read(int index) => _array.get(index);
  void save(int index) => _saved = _array.get(index);
  SharedBytes? saved() => _saved;
  int readSaved(int index) => _saved![index];
  void changeSaved(int index, int value) => _saved![index] = value;
  void writeSaved(int index) => _array.set(index, _saved);
  void clear(int index) => _array.set(index, null);
  void captureEntry() => _entry = _map.entries.first;
  SharedBytes? key() => _entry?.$1;
  SharedBytes? value() => _entry?.$2;
  bool hasEntry() => _map.has(_entry!.$1);
  bool sameEntryValue() => identical(_map.get(_entry!.$1), _entry!.$2);
  void writeEntry() => _map.set(_entry!.$1, _entry!.$2);
  void allocate(int index) {
    _saved = SharedBytes.allocate(2);
    _array.set(index, _saved);
  }
}

@NAPI()
bool binarySharedPolicy(
  JsArray<Uint8List?> copied,
  JsArray<SharedBytes?> shared,
) => identical(copied, shared);

typedef StructuralElement = ({
  String text,
  List<int?> values,
  Map<String, Uint8List?> bytes,
  Dictionary<SharedBytes?> shared,
});

@NAPI()
class StructuralCollections {
  final JsArray<StructuralElement?> _array;
  final JsMap<String, StructuralElement?> _map;
  StructuralElement? _saved;
  StructuralCollections(this._array, this._map);
  JsArray<StructuralElement?> array() => _array;
  JsMap<String, StructuralElement?> map() => _map;
  StructuralElement? read(int index) => _array.get(index);
  StructuralElement? get(String key) => _map.get(key);
  StructuralElement? first() => _map.entries.first.$2;
  void save(int index) => _saved = _array.get(index);
  StructuralElement? saved() => _saved;
  void change(int value) {
    _saved!.values[0] = value;
    _saved!.bytes['key']![0] = value;
  }

  void writeSaved(int index) => _array.set(index, _saved);
  void putSaved(String key) => _map.set(key, _saved);
  void unsafe() => _saved!.values[0] = 9007199254740992;
  bool catchesWrite(int index) {
    try {
      _array.set(index, _saved);
      return false;
    } catch (_) {
      return true;
    }
  }

  bool independentReads() =>
      !identical(_array.get(0)!.values, _array.get(0)!.values);
  bool catches(int index) {
    try {
      _array.get(index);
      return false;
    } catch (_) {
      return true;
    }
  }
}

@NAPI()
bool structuralKeys(JsMap<List<int>, Dictionary<int>> value) {
  final (key, item) = value.entries.first;
  if (value.has(key) || value.get(key) != null || value.delete(key)) {
    return false;
  }
  value.set(key, item);
  key[0] = 9;
  item['value'] = 10;
  return true;
}

@NAPI()
List<int>? recordKey(JsMap<({int id}), List<int>> value) =>
    value.entries.first.$2;

@NAPI()
bool containerKeys(
  JsMap<Map<String, int>, Dictionary<int>> maps,
  JsMap<Dictionary<int>, List<int>> dictionaries,
) {
  final (mapKey, mapValue) = maps.entries.first;
  final (dictKey, dictValue) = dictionaries.entries.first;
  if (maps.has(mapKey) || dictionaries.has(dictKey)) {
    return false;
  }
  maps.set(mapKey, mapValue);
  dictionaries.set(dictKey, dictValue);
  mapKey['key'] = 9;
  mapValue['value'] = 9;
  dictKey['key'] = 9;
  dictValue[0] = 9;
  return true;
}

@NAPI()
bool recordMapCollision(JsArray<Map<({int id}), int>> value, bool catchError) {
  try {
    value.get(0);
    return false;
  } catch (_) {
    if (catchError) return true;
    rethrow;
  }
}

@NAPI(bigint: true)
JsArray<List<int>> structuralBigints(JsArray<List<int>> value) {
  value.set(0, value.get(0)!);
  return value;
}

@NAPI()
JsArray<List<BigInt>> structuralWideBigints(JsArray<List<BigInt>> value) {
  value.set(0, value.get(0)!);
  return value;
}

@NAPI()
int mixedResourceEntries(JsMap<ResourceItem, List<int>> value) {
  final (key, item) = value.entries.first;
  return key.value + item.first;
}

@NAPI()
List<int>? structuralCallback(
  JsArray<List<int>> Function(JsArray<List<int>>) callback,
  JsArray<List<int>> value,
) => callback(value).get(0);

typedef CopiedPayload<T> = ({RefItem reference, T payload, JsArray<T> handle});

@NAPI()
class CopiedPayloads<T> {
  final JsArray<CopiedPayload<T>> _source;
  CopiedPayload<T>? _saved;
  CopiedPayloads(this._source);
  JsArray<CopiedPayload<T>> source() => _source;
  bool load(int index) {
    _saved = _source.get(index);
    return _saved != null;
  }

  CopiedPayload<T>? saved() => _saved;
  RefItem? reference() => _saved?.reference;
  T? payload() => _saved?.payload;
  JsArray<T>? handle() => _saved?.handle;
  T? readInner(int index) => _saved!.handle.get(index);
  void write(int index) => _source.set(index, _saved!);
  void clear() => _saved = null;
}

@NAPI()
JsArray<List<T>> pureCopiedPayload<T>(JsArray<List<T>> value) {
  value.set(1, value.get(0)!);
  return value;
}

typedef CopiedResource = ({ResourceItem resource, List<int> values});
typedef CopiedResourceOutput = (
  ResourceItem, {
  List<int> list,
  Map<String, int> map,
  Dictionary<int> dict,
});

class _ClosingList extends ListBase<int> {
  final void Function() close;
  _ClosingList(this.close);
  @override
  int get length => 1;
  @override
  set length(int value) => throw UnsupportedError('fixed');
  @override
  int operator [](int index) {
    close();
    return 1;
  }

  @override
  void operator []=(int index, int value) => throw UnsupportedError('fixed');
}

class _ClosingMap extends MapBase<String, int> {
  final void Function() close;
  _ClosingMap(this.close);
  @override
  int get length => 1;
  @override
  Iterable<String> get keys {
    close();
    return ['key'];
  }

  @override
  int? operator [](Object? key) => 1;
  @override
  void operator []=(String key, int value) => throw UnsupportedError('fixed');
  @override
  void clear() => throw UnsupportedError('fixed');
  @override
  int? remove(Object? key) => throw UnsupportedError('fixed');
}

class _ResourceEntries<K> extends MapBase<K, ResourceItem?> {
  final K firstKey;
  final K lastKey;
  final ResourceItem resource;
  final void Function() close;
  _ResourceEntries(this.firstKey, this.lastKey, this.resource, this.close);
  @override
  int get length => 2;
  @override
  Iterable<K> get keys sync* {
    yield firstKey;
    close();
    yield lastKey;
  }

  @override
  ResourceItem? operator [](Object? key) =>
      identical(key, firstKey) ? resource : null;
  @override
  void operator []=(K key, ResourceItem? value) =>
      throw UnsupportedError('fixed');
  @override
  void clear() => throw UnsupportedError('fixed');
  @override
  ResourceItem? remove(Object? key) => throw UnsupportedError('fixed');
}

@NAPI()
class CopiedResources {
  final JsArray<CopiedResource> _source;
  CopiedResource? _saved;
  CopiedResources(this._source);
  void load() => _saved = _source.get(0);
  void write() => _source.set(0, _saved!);
  void output(
    JsArray<CopiedResourceOutput> target,
    int kind,
    void Function() close,
  ) => target.set(0, (
    _saved!.resource,
    list: kind == 0 ? _ClosingList(close) : [],
    map: kind == 1 ? _ClosingMap(close) : {},
    dict: Dictionary(kind == 2 ? _ClosingMap(close) : {}),
  ));
  void outputEntries(
    JsArray<Map<ResourceItem?, ResourceItem?>> maps,
    JsArray<Dictionary<ResourceItem?>> dictionaries,
    bool dictionary,
    void Function() close,
  ) {
    final resource = _saved!.resource;
    if (dictionary) {
      dictionaries.set(
        0,
        Dictionary(_ResourceEntries('first', 'last', resource, close)),
      );
    } else {
      maps.set(0, _ResourceEntries(resource, null, resource, close));
    }
  }

  Future<int> hold(int token) async {
    final value = _source.get(0)!;
    await _collectionGate(token);
    return value.resource.value;
  }

  Stream<int> watch(int token) {
    late StreamController<int> controller;
    controller = StreamController<int>(
      onListen: () async {
        try {
          await _collectionGate(token);
          controller.add(_source.get(0)!.resource.value);
        } catch (error, stack) {
          controller.addError(error, stack);
        }
      },
      onCancel: () => _collectionGate(-token),
    );
    return controller.stream;
  }

  void timer(bool write) {
    _collectionTimer = [];
    Timer(const Duration(milliseconds: 1), () {
      try {
        if (write) {
          _source.set(0, _saved!);
        } else {
          _source.get(0);
        }
        _collectionTimer.add(0);
      } catch (_) {
        _collectionTimer.add(1);
      }
    });
  }
}
