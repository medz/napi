import 'dart:async';

import 'package:napi/napi.dart';

import 'opaque_hierarchy.dart';

export 'opaque_hierarchy.dart';

int _calls = 0;
Object? _pinned;
Completer<int>? _pending;
List<int> _allocation = [];

@NAPI(classPolicy: ClassPolicy.value)
class GenericValue<T> {
  GenericValue(this.value, {this.optional, this.items = const []});
  final T value;
  final T? optional;
  final List<T> items;
}

@NAPI()
GenericValue<T> opaqueValueEcho<T>(GenericValue<T> value) => value;

@NAPI()
GenericValue<T> opaqueValueCallback<T>(
  GenericValue<T> value,
  GenericValue<T> Function(GenericValue<T>) callback,
) => callback(value);

@NAPI()
int opaqueCalls() => _calls;

@NAPI()
T identity<T>(T value) {
  _calls++;
  return value;
}

@NAPI()
T? optional<T>([T? value]) {
  _calls++;
  return value;
}

@NAPI()
Future<T> futureIdentity<T>(T value) {
  _calls++;
  return Future.value(value);
}

@NAPI()
Future<T?> futureOptional<T>([T? value]) => Future.value(value);

@NAPI()
Future<T> futureDelayed<T>(T value, int milliseconds) =>
    Future.delayed(Duration(milliseconds: milliseconds), () => value);

@NAPI()
T? prefix<T>([T? first, int choose = 7, T? last]) => choose == 7 ? first : last;

@NAPI()
T? named<T>(int marker, {T? first, T? second, int choose = 7}) {
  _calls++;
  return marker == choose ? first : second;
}

@NAPI()
T? mixedRequired<T>({required T first, T? second, int choose = 7}) {
  _calls++;
  return choose == 7 ? first : second;
}

@NAPI()
Future<T?> futureNamed<T>(int marker, {T? first, T? second, int choose = 7}) =>
    Future.value(named(marker, first: first, second: second, choose: choose));

@NAPI()
class NamedStore<T> {
  T? first;
  T? second;
  int marker = 7;

  NamedStore({this.first, this.second}) {
    _calls++;
  }
  NamedStore.withMarker(this.marker, {this.first, this.second}) {
    _calls++;
  }

  T? select(int marker, {T? first, T? second, int choose = 7}) =>
      named(marker, first: first, second: second, choose: choose);
  Future<T?> futureSelect(int marker, {T? first, T? second, int choose = 7}) =>
      futureNamed(marker, first: first, second: second, choose: choose);
  void clear() {
    first = null;
    second = null;
  }
}

@NAPI()
Future<int> waitNamed<T>({T? first, T? second}) {
  // The bridge retains both supplied payloads; this Future captures neither.
  _pending = Completer<int>();
  return _pending!.future;
}

@NAPI()
List<int> opaqueArray<Array>(Array value) => [1, 2];

@NAPI()
// Deliberate type-name collision exercises generated TypeScript hygiene.
// ignore: avoid_types_as_parameter_names
() opaqueRecord<Record>(Record value) => ();

@NAPI()
() opaqueKey<PropertyKey>(PropertyKey value) => ();

@NAPI()
Future<Map<String, int>> opaqueGlobal<globalThis>(globalThis value) =>
    Future.value({'size': 1});

@NAPI()
class Router<T> {
  final Map<String, T> _values = {};
  T? value;

  Router();
  Router.withValue(T initial) {
    _calls++;
    _values['initial'] = initial;
  }

  int get size => _values.length;
  void set(String key, T payload) {
    _calls++;
    _values[key] = payload;
  }

  T? get(String key) => _values[key];
  Future<T?> futureGet(String key) => Future.value(_values[key]);
  Future<T?> get futureValue => Future.value(value);
  bool has(String key) => _values.containsKey(key);
  bool remove(String key) => _values.remove(key) != null;
  void put({required String key, required T value}) => set(key, value);
  T? optional([T? value]) => value;
  Router<T> self() => this;
  void clear() {
    _values.clear();
    value = null;
  }

  void pin() => _pinned = this;
}

@NAPI()
Router<T> forwardRouter<T>(Router<T> value) => value;

@NAPI()
Router<T> readoptRouter<T>() => _pinned as Router<T>;

@NAPI()
int unpinRouter() {
  _pinned = null;
  return 0;
}

// Generic declaration order defines the public constructor/type relationship.
@NAPI()
class Pair<First, Second> {
  First first;
  Second second;
  Pair(this.first, this.second);
}

@NAPI()
class Bounded<T extends Object> {
  T value;
  Bounded(this.value);
}

@NAPI()
Future<int> waitOpaque<T>(T value) {
  // No business closure or field retains the payload. The binding owns the
  // accepted input until the returned Future settles.
  _pending = Completer<int>();
  return _pending!.future;
}

@NAPI()
class NestedStore<T> {
  List<T> values = [];
  NestedStore();

  List<List<T?>> lists(List<List<T?>> value) => value;
  Dictionary<T> dictionary(Dictionary<T> value) => value;
  Map<String, List<T?>> map(Map<String, List<T?>> value) => value;
  ({T value, List<T> rest}) record(({T value, List<T> rest}) value) => value;
  List<NamedStore<T>> references(List<NamedStore<T>> value) => value;
  List<bool> nulls(List<T?> value) => [for (final item in value) item == null];
  List<T?> withNull(List<T> value) => [null, ...value];

  void saveThrow(List<T> value) {
    values = value;
    throw StateError('saved nested input');
  }

  int checked(List<({T value, int count})> value, int later) {
    _calls++;
    return value.length + later;
  }

  ({List<T> values, int invalid}) badOutput(List<T> value) {
    values = value;
    return (values: value, invalid: 9007199254740992);
  }

  void clear() => values = [];
  Future<List<T>> futureList(List<T> value) async => value;
  Future<({T then})> futureThen(List<T> value) async => (then: value.first);
  Future<Dictionary<T>> futureDictionary(Dictionary<T> value) async => value;
  Stream<({T then})> streamThen(List<T> value) =>
      Stream.value((then: value.first));
  Future<int> wait(List<T> value) => waitOpaque(value);
  Stream<int> hold(List<T> value) => const Stream.empty();
}

@NAPI()
List<OpaquePair<Y, X>> nestedPairs<X, Y>(List<OpaquePairChild<X, Y>> values) =>
    values;

@NAPI()
int completeOpaque(int value) {
  _pending!.complete(value);
  _pending = null;
  return 0;
}

@NAPI()
int opaquePressure(int seed) {
  _allocation = List<int>.generate(1000000, (index) => index + seed);
  return _allocation.last;
}

@NAPI(name: 'Array')
class ArrayStorage<T> {
  T value;
  ArrayStorage(this.value);
  List<int> numbers() => [1, 2];
}

@NAPI(name: 'Record')
class EmptyRecord<T> {
  EmptyRecord();
  () empty() => ();
}

@NAPI()
Future<Router<T>> futureRouter<T>(Router<T> value) => Future.value(value);

@NAPI()
Future<Awaited> opaqueAwaited<Awaited>(Awaited value) => Future.value(value);

@NAPI(name: 'Awaited')
class AwaitedStorage<T> {
  T value;
  AwaitedStorage(this.value);
}

@NAPI()
class ThenBox<T> {
  T then;
  ThenBox(this.then);
  Future<ThenBox<T>> futureSelf() => Future.value(this);
}

@NAPI()
Future<ThenBox<T>> futureThenBox<T>(ThenBox<T> value) => Future.value(value);

// Selected from a second build through the public ExternalLibrary API.
T plainEcho<T>(T value) => value;

Future<T> plainFuture<T>(T value) => Future.value(value);

class PlainStore<T> {
  T value;
  PlainStore(this.value);
  Future<T> futureValue() => Future.value(value);
}

@NAPI()
class SetterThenBox<T> {
  T _value;
  SetterThenBox(this._value);
  set then(T value) => _value = value;
  T get value => _value;
  Future<SetterThenBox<T>> futureSelf() => Future.value(this);
}

@NAPI()
class StaticSetterThenBox {
  static set then(void Function() value) => value();
}

@NAPI()
class GetterThenView<T> {
  GetterThenView(this._value);
  final T _value;
  T get then => _value;
}

class _CompositeThen<T> extends SetterThenBox<T> implements GetterThenView<T> {
  _CompositeThen(super.value);
  @override
  T get then => value;
}

@NAPI()
SetterThenBox<T> compositeThen<T>(T value) => _CompositeThen(value);

@NAPI()
class MethodBox<T> {
  T value;
  Object? _saved;
  MethodBox(this.value);

  U echo<U>(U value) => value;
  U? optional<U>([U? value]) => value;
  U? named<U>(int marker, {U? first, U? second, int choose = 7}) =>
      marker == choose ? first : second;
  U requiredNamed<U>({required U value}) => value;
  (T, U) both<U>(U value) => (this.value, value);
  Router<U> wrap<U>(U value) => Router<U>.withValue(value);
  List<Router<U>> references<U>(List<Router<U>> value) => value;
  List<U?> list<U>(List<U?> value) => value;
  Dictionary<U> dictionary<U>(Dictionary<U> value) => value;
  JsArray<U> array<U>(JsArray<U> value) => value;
  JsMap<T, U> map<U>(JsMap<T, U> value) => value;
  Future<U> later<U>(U value) async => value;
  Future<Dictionary<U>> futureDictionary<U>(Dictionary<U> value) async => value;
  Stream<U> events<U>(U value) => Stream.value(value);
  Future<int> wait<U>(U ignored) => waitOpaque(ignored);
  Stream<int> hold<U>(U ignored) => const Stream.empty();
  U callback<U>(U value, void Function(int) callback) {
    callback(7);
    return value;
  }

  int checked<U>(List<({U value, int count})> values, int later) {
    _calls++;
    return values.length + later;
  }

  void saveThrow<U>(U value) {
    _saved = value;
    throw StateError('saved method input');
  }

  U saved<U>() => _saved as U;
  void clear() => _saved = null;
  int unused<U>() => 7;
  @NAPI(name: 'staticEcho')
  static U echoStatic<U>(U value) => value;
}

@NAPI()
class MethodShadow<T> {
  MethodShadow();
  // ignore: avoid_shadowing_type_parameters
  T echo<T>(T value) => value;
}

class MethodBusiness<T extends num> {
  T value;
  MethodBusiness(this.value);
  (T, U) pair<U>(U value) => (this.value, value);
}

@NAPI()
typedef MethodInt = MethodBusiness<int>;

@NAPI()
class MethodA {
  MethodA();
  U echo<U>(U value) => value;
}

@NAPI()
class MethodB {
  MethodB();
  V echo<V>(V value) => value;
}

class _MethodComposite implements MethodA, MethodB {
  @override
  W echo<W>(W value) => value;
}

@NAPI()
MethodA methodComposite() => _MethodComposite();

int _methodCleanups = 0;

@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class MethodSession {
  MethodSession();
  Future<int> pending<U>(U ignored) => waitOpaque(ignored);
  Future<U> later<U>(U value) async => value;
  Stream<int> hold<U>(U ignored) => const Stream.empty();
  void close() => _methodCleanups++;
}

@NAPI()
int methodCleanups() => _methodCleanups;

@NAPI()
class MethodInherited<T> extends MethodBox<T> {
  MethodInherited(super.value);
}

@NAPI()
class MethodOverride<T> extends MethodBox<T> {
  MethodOverride(super.value);
  @override
  V echo<V>(V value) => value;
  @override
  V? named<V>(int marker, {V? first, V? second, int choose = 9}) =>
      marker == choose ? first : second;
}

@NAPI()
class MethodContract<T> {
  MethodContract();
  (T, U, int) combine<U>(T first, U second, [int step = 7]) =>
      (first, second, step);
}

mixin _MethodMixin<T> {
  (T, V, int) combine<V>(T first, V second, [int step = 11]) =>
      (first, second, step);
}

@NAPI()
class MethodInterface<U> with _MethodMixin<U> implements MethodContract<U> {
  MethodInterface();
}

@NAPI()
class MethodPair<A, B> {
  MethodPair();
  (A, B, U) combine<U>(A first, B second, U third) => (first, second, third);
}

@NAPI()
class MethodPairChild<X, Y> extends MethodPair<Y, X> {
  MethodPairChild();
  @override
  (Y, X, Z) combine<Z>(Y first, X second, Z third) => (first, second, third);
}

@NAPI()
class MethodIntChild extends MethodInt {
  MethodIntChild(super.value);
}

@NAPI()
class MethodInheritedSession extends MethodSession {
  MethodInheritedSession();
}

@NAPI()
class MethodDefaultA {
  MethodDefaultA();
  U? choose<U>([U? value, int index = 7]) => value;
}

@NAPI()
class MethodDefaultB {
  MethodDefaultB();
  V? choose<V>([V? value, int index = 9]) => value;
}

class _MethodDefaultConflict implements MethodDefaultA, MethodDefaultB {
  @override
  W? choose<W>([W? value, int index = 11]) => value;
}

@NAPI()
MethodDefaultA methodDefaultConflict() => _MethodDefaultConflict();
