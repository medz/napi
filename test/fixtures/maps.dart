import 'dart:collection';

import 'package:napi/napi.dart';

import 'classes.dart';
export 'classes.dart';

int _calls = 0;
Map<RefBox?, RefBox?>? _held;

@NAPI()
int mapCalls() => _calls;
@NAPI()
Map<String, int> echoMap(Map<String, int> value) {
  _calls++;
  return value;
}

@NAPI()
Map<String, List<(int, {RefBox? owner})?>?> nestedMap(
  Map<String, List<(int, {RefBox? owner})?>?> value,
) => value;
@NAPI()
Map<(int,), String> recordKeyMap(Map<(int,), String> value) => value;
@NAPI()
Map<RefBox?, RefBox?> referenceMap(Map<RefBox?, RefBox?> value) => value;
@NAPI()
int holdMap(Map<RefBox?, RefBox?>? value) {
  _held = value;
  return 0;
}

@NAPI()
Map<RefBox?, RefBox?>? heldMap() => _held;
@NAPI()
Map<double, String> doubleMap(Map<double, String> value) => value;
@NAPI()
bool mapFindsNaN(Map<double, String> value) => value.containsKey(double.nan);
@NAPI()
Map<double, String> duplicateNaNMap() => _nanEntries('first', 'second');
@NAPI(bigint: true)
Map<int, BigInt?> bigintMap(Map<int, BigInt?> value) => value;
@NAPI()
Map<String, int>? optionalMap([Map<String, int>? value]) => value;
@NAPI()
Map<String, int>? namedMap({required Map<String, int>? value}) => value;
@NAPI()
Map<String, Map<String, int>> recursiveMap(
  Map<String, Map<String, int>> value,
) => value;

@NAPI()
class MapHolder {
  Map<String, int> values;
  final Map<String, int>? initial;
  MapHolder(this.values, {this.initial});
  Map<String, int> replace(Map<String, int> value) => values = value;
  static Map<String, int> echo(Map<String, int> value) => value;
}

@NAPI(name: 'Map')
class UserMap {
  UserMap(this.value);
  int value;
  UserMap self() => this;
}

@NAPI()
Map<UserMap, UserMap> userMap(Map<UserMap, UserMap> value) => value;

@NAPI()
class MapKey {
  final int id;
  bool failHash = false;
  bool failEquals = false;
  MapKey(this.id);
  @override
  @NAPI(exclude: true)
  int get hashCode => failHash ? throw StateError('Map hash failed') : 0;
  @override
  @NAPI(exclude: true)
  bool operator ==(Object other) {
    if (failEquals) throw StateError('Map equality failed');
    return other is MapKey && other.id == id;
  }
}

@NAPI()
Map<MapKey, int> equalKeyMap(Map<MapKey, int> value) => value;

@NAPI()
Map<int, int> customMap(int length, bool failEntries) =>
    _CustomMap(length, failEntries);

class _CustomMap extends MapBase<int, int> {
  final int reportedLength;
  final bool failEntries;
  _CustomMap(this.reportedLength, this.failEntries);
  @override
  int get length => reportedLength;
  @override
  Iterable<MapEntry<int, int>> get entries sync* {
    if (failEntries) throw StateError('Map entries failed');
    yield const MapEntry(1, 2);
  }

  @override
  Iterable<int> get keys => const [1];
  @override
  int? operator [](Object? key) => key == 1 ? 2 : null;
  @override
  void operator []=(int key, int value) => throw UnsupportedError('readonly');
  @override
  void clear() => throw UnsupportedError('readonly');
  @override
  int? remove(Object? key) => throw UnsupportedError('readonly');
}

RefChild? _partial;
@NAPI()
Map<double, RefBase> failingMapReference() {
  _partial = RefChild();
  return _nanEntries(_partial!, _partial!);
}

@NAPI()
RefChild mapReferenceChild() => _partial!;
@NAPI()
Map<double, RefBase> failingExistingMapReference(RefBase value) =>
    _nanEntries(value, value);

Map<double, T> _nanEntries<T>(T first, T second) => <double, T>{}
  ..[double.nan] = first
  ..[double.nan] = second;
