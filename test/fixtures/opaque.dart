import 'dart:async';

import 'package:napi/napi.dart';

int _calls = 0;
Object? _pinned;
Completer<int>? _pending;
List<int> _allocation = [];

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
