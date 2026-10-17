import 'dart:async';

import 'package:napi/napi.dart';

int _calls = 0;
Object? _pinned;
Completer<int>? _pending;
List<int> _allocation = [];

@NAPI()
int opaqueCalls() => _calls;

@NAPI(opaque: ['T'])
T identity<T>(T value) {
  _calls++;
  return value;
}

@NAPI(opaque: ['T'])
T? optional<T>([T? value]) {
  _calls++;
  return value;
}

@NAPI(opaque: ['T'])
T? prefix<T>([T? first, int choose = 7, T? last]) => choose == 7 ? first : last;

@NAPI(opaque: ['Array'])
List<int> opaqueArray<Array>(Array value) => [1, 2];

@NAPI(opaque: ['Record'])
// Deliberate type-name collision exercises generated TypeScript hygiene.
// ignore: avoid_types_as_parameter_names
() opaqueRecord<Record>(Record value) => ();

@NAPI(opaque: ['PropertyKey'])
() opaqueKey<PropertyKey>(PropertyKey value) => ();

@NAPI(opaque: ['globalThis'])
Future<Map<String, int>> opaqueGlobal<globalThis>(globalThis value) =>
    Future.value({'size': 1});

@NAPI(opaque: ['T'])
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

@NAPI(opaque: ['T'])
Router<T> forwardRouter<T>(Router<T> value) => value;

@NAPI(opaque: ['T'])
Router<T> readoptRouter<T>() => _pinned as Router<T>;

@NAPI()
int unpinRouter() {
  _pinned = null;
  return 0;
}

// Annotation order is intentionally different from declaration order.
@NAPI(opaque: ['Second', 'First'])
class Pair<First, Second> {
  First first;
  Second second;
  Pair(this.first, this.second);
}

@NAPI(opaque: ['T'])
class Bounded<T extends Object> {
  T value;
  Bounded(this.value);
}

@NAPI(opaque: ['T'])
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

// Selected from a second build through the public ExternalLibrary API.
T plainEcho<T>(T value) => value;

class PlainStore<T> {
  T value;
  PlainStore(this.value);
}
