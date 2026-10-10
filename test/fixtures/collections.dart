import 'dart:collection';
import 'dart:typed_data';

import 'package:napi/napi.dart';

typedef Flag = bool;
typedef UserId = int;
typedef Key = String;
typedef Bytes = Uint8List;

@napi
List<Bytes> listBytes(List<Bytes> values) => values;

@napi
Future<List<Uint8List>> listBytesAsync(List<Uint8List> values) async {
  await Future<void>.value();
  return values;
}

@napi
List<Uint8List?> listNullableBytes(List<Uint8List?> values) => values;

@napi
Future<List<Uint8List?>> listNullableBytesAsync(List<Uint8List?> values) async {
  await Future<void>.value();
  return values;
}

@napi
List<Uint8List>? listNullableContainerBytes(List<Uint8List>? values) => values;

@napi
Future<List<Uint8List>?> listNullableContainerBytesAsync(
  List<Uint8List>? values,
) async {
  await Future<void>.value();
  return values;
}

@napi
List<Uint8List?>? listNullableBothBytes(List<Uint8List?>? values) => values;

@napi
Future<List<Uint8List?>?> listNullableBothBytesAsync(
  List<Uint8List?>? values,
) async {
  await Future<void>.value();
  return values;
}

@napi
List<Uint8List> invertAll(List<Uint8List> values) {
  for (final bytes in values) {
    for (var index = 0; index < bytes.length; index++) {
      bytes[index] ^= 0xff;
    }
  }
  return values;
}

@napi
Future<List<Uint8List>> invertAllAsync(List<Uint8List> values) async {
  invertAll(values);
  await Future<void>.value();
  return values;
}

@napi
List<Flag> listBool(List<Flag> values) => values;

@napi
Future<List<bool>> listBoolAsync(List<bool> values) async {
  await Future<void>.value();
  return values;
}

@napi
List<bool?> listNullableBool(List<bool?> values) => values;

@napi
Future<List<bool?>> listNullableBoolAsync(List<bool?> values) async {
  await Future<void>.value();
  return values;
}

@napi
List<bool>? listNullableContainerBool(List<bool>? values) => values;

@napi
Future<List<bool>?> listNullableContainerBoolAsync(List<bool>? values) async {
  await Future<void>.value();
  return values;
}

@napi
List<bool?>? listNullableBothBool(List<bool?>? values) => values;

@napi
Future<List<bool?>?> listNullableBothBoolAsync(List<bool?>? values) async {
  await Future<void>.value();
  return values;
}

@napi
List<int> listInt(List<int> values) => values;

@napi
Future<List<UserId>> listIntAsync(List<UserId> values) async {
  await Future<void>.value();
  return values;
}

@napi
List<UserId?> listNullableInt(List<UserId?> values) => values;

@napi
Future<List<int?>> listNullableIntAsync(List<int?> values) async {
  await Future<void>.value();
  return values;
}

@napi
List<int>? listNullableContainerInt(List<int>? values) => values;

@napi
Future<List<int>?> listNullableContainerIntAsync(List<int>? values) async {
  await Future<void>.value();
  return values;
}

@napi
List<int?>? listNullableBothInt(List<int?>? values) => values;

@napi
Future<List<int?>?> listNullableBothIntAsync(List<int?>? values) async {
  await Future<void>.value();
  return values;
}

@napi
List<double> listDouble(List<double> values) => values;

@napi
Future<List<double>> listDoubleAsync(List<double> values) async {
  await Future<void>.value();
  return values;
}

@napi
List<double?> listNullableDouble(List<double?> values) => values;

@napi
Future<List<double?>> listNullableDoubleAsync(List<double?> values) async {
  await Future<void>.value();
  return values;
}

@napi
List<double>? listNullableContainerDouble(List<double>? values) => values;

@napi
Future<List<double>?> listNullableContainerDoubleAsync(
  List<double>? values,
) async {
  await Future<void>.value();
  return values;
}

@napi
List<double?>? listNullableBothDouble(List<double?>? values) => values;

@napi
Future<List<double?>?> listNullableBothDoubleAsync(
  List<double?>? values,
) async {
  await Future<void>.value();
  return values;
}

@napi
List<String> listString(List<String> values) => values;

@napi
Future<List<String>> listStringAsync(List<String> values) async {
  await Future<void>.value();
  return values;
}

@napi
List<String?> listNullableString(List<String?> values) => values;

@napi
Future<List<String?>> listNullableStringAsync(List<String?> values) async {
  await Future<void>.value();
  return values;
}

@napi
List<String>? listNullableContainerString(List<String>? values) => values;

@napi
Future<List<String>?> listNullableContainerStringAsync(
  List<String>? values,
) async {
  await Future<void>.value();
  return values;
}

@napi
List<String?>? listNullableBothString(List<String?>? values) => values;

@napi
Future<List<String?>?> listNullableBothStringAsync(
  List<String?>? values,
) async {
  await Future<void>.value();
  return values;
}

@napi
Map<String, bool> mapBool(Map<String, bool> values) => values;

@napi
Future<Map<String, bool>> mapBoolAsync(Map<String, bool> values) async {
  await Future<void>.value();
  return values;
}

@napi
Map<String, bool?> mapNullableBool(Map<String, bool?> values) => values;

@napi
Future<Map<String, bool?>> mapNullableBoolAsync(
  Map<String, bool?> values,
) async {
  await Future<void>.value();
  return values;
}

@napi
Map<String, bool>? mapNullableContainerBool(Map<String, bool>? values) =>
    values;

@napi
Future<Map<String, bool>?> mapNullableContainerBoolAsync(
  Map<String, bool>? values,
) async {
  await Future<void>.value();
  return values;
}

@napi
Map<String, bool?>? mapNullableBothBool(Map<String, bool?>? values) => values;

@napi
Future<Map<String, bool?>?> mapNullableBothBoolAsync(
  Map<String, bool?>? values,
) async {
  await Future<void>.value();
  return values;
}

@napi
Map<Key, UserId> mapInt(Map<Key, UserId> values) => values;

@napi
Future<Map<String, int>> mapIntAsync(Map<String, int> values) async {
  await Future<void>.value();
  return values;
}

@napi
Map<Key, UserId?> mapNullableInt(Map<Key, UserId?> values) => values;

@napi
Future<Map<String, int?>> mapNullableIntAsync(Map<String, int?> values) async {
  await Future<void>.value();
  return values;
}

@napi
Map<String, int>? mapNullableContainerInt(Map<String, int>? values) => values;

@napi
Future<Map<String, int>?> mapNullableContainerIntAsync(
  Map<String, int>? values,
) async {
  await Future<void>.value();
  return values;
}

@napi
Map<String, int?>? mapNullableBothInt(Map<String, int?>? values) => values;

@napi
Future<Map<String, int?>?> mapNullableBothIntAsync(
  Map<String, int?>? values,
) async {
  await Future<void>.value();
  return values;
}

@napi
Map<String, double> mapDouble(Map<String, double> values) => values;

@napi
Future<Map<String, double>> mapDoubleAsync(Map<String, double> values) async {
  await Future<void>.value();
  return values;
}

@napi
Map<String, double?> mapNullableDouble(Map<String, double?> values) => values;

@napi
Future<Map<String, double?>> mapNullableDoubleAsync(
  Map<String, double?> values,
) async {
  await Future<void>.value();
  return values;
}

@napi
Map<String, double>? mapNullableContainerDouble(Map<String, double>? values) =>
    values;

@napi
Future<Map<String, double>?> mapNullableContainerDoubleAsync(
  Map<String, double>? values,
) async {
  await Future<void>.value();
  return values;
}

@napi
Map<String, double?>? mapNullableBothDouble(Map<String, double?>? values) =>
    values;

@napi
Future<Map<String, double?>?> mapNullableBothDoubleAsync(
  Map<String, double?>? values,
) async {
  await Future<void>.value();
  return values;
}

@napi
Map<String, String> mapString(Map<String, String> values) => values;

@napi
Future<Map<Key, Key>> mapStringAsync(Map<Key, Key> values) async {
  await Future<void>.value();
  return values;
}

@napi
Map<String, String?> mapNullableString(Map<String, String?> values) => values;

@napi
Future<Map<String, String?>> mapNullableStringAsync(
  Map<String, String?> values,
) async {
  await Future<void>.value();
  return values;
}

@napi
Map<String, String>? mapNullableContainerString(Map<String, String>? values) =>
    values;

@napi
Future<Map<String, String>?> mapNullableContainerStringAsync(
  Map<String, String>? values,
) async {
  await Future<void>.value();
  return values;
}

@napi
Map<String, String?>? mapNullableBothString(Map<String, String?>? values) =>
    values;

@napi
Future<Map<String, String?>?> mapNullableBothStringAsync(
  Map<String, String?>? values,
) async {
  await Future<void>.value();
  return values;
}

var _calls = 0;
List<int> _list = [];
Map<String, String?> _map = {};
List<Uint8List> _bytes = [];

@napi
int calls() => _calls;

@napi
List<int> trackedList(List<int> values, Map<String, int> labels) {
  _calls++;
  _list = values;
  return values;
}

@napi
Future<List<int>> trackedListAsync(
  List<int> values,
  Map<String, int> labels,
) async {
  _calls++;
  _list = values;
  await Future<void>.value();
  return values;
}

@napi
Map<String, String?> trackedMap(
  Map<String, String?> values,
  List<int> markers,
) {
  _calls++;
  _map = values;
  return values;
}

@napi
Future<Map<String, String?>> trackedMapAsync(
  Map<String, String?> values,
  List<int> markers,
) async {
  _calls++;
  _map = values;
  await Future<void>.value();
  return values;
}

@napi
List<Uint8List> trackedBytes(List<Uint8List> first, List<Uint8List> second) {
  _calls++;
  _bytes = first;
  return second;
}

@napi
Future<List<Uint8List>> trackedBytesAsync(
  List<Uint8List> first,
  List<Uint8List> second,
) async {
  _calls++;
  _bytes = first;
  await Future<void>.value();
  return second;
}

@napi
List<Uint8List> readBytes() => _bytes;

@napi
Future<List<Uint8List>> readBytesAsync() async => _bytes;

@napi
List<int> readList() => _list;

@napi
Future<List<int>> readListAsync() async => _list;

@napi
Map<String, String?> readMap() => _map;

@napi
Future<Map<String, String?>> readMapAsync() async => _map;

@napi
void changeRetained() {
  if (_list.isNotEmpty) _list[0] = -7;
  _map['stored'] = 'changed';
  if (_bytes.isNotEmpty) {
    if (_bytes.first.isNotEmpty) _bytes.first[0] ^= 0xff;
    _bytes.add(_bytes.first);
  }
}

@napi
List<int> unsafeList() => [1, 9007199254740992];

@napi
Future<List<int>> unsafeListAsync() async => unsafeList();

@napi
Map<String, int> unsafeMap() => {'valid': 1, 'bad': 9007199254740992};

@napi
Future<Map<String, int>> unsafeMapAsync() async => unsafeMap();

final class _BadMessage {
  @override
  String toString() => throw StateError('replacement range formatter error');
}

final class _BadTypeError extends TypeError {
  @override
  String toString() => throw StateError('replacement type formatter error');
}

final class _FailingList extends ListBase<int> {
  _FailingList(this.error);
  final Object error;
  @override
  int get length => 1;
  @override
  set length(int value) => throw UnimplementedError();
  @override
  int operator [](int index) => throw error;
  @override
  void operator []=(int index, int value) => throw UnimplementedError();
}

final class _FailingByteList extends ListBase<Uint8List> {
  _FailingByteList(this._length);
  final int _length;
  @override
  int get length => _length;
  @override
  set length(int value) => throw UnimplementedError();
  @override
  Uint8List operator [](int index) {
    if (index == 0) return Uint8List.fromList([1]);
    throw RangeError('byte getter');
  }

  @override
  void operator []=(int index, Uint8List value) => throw UnimplementedError();
}

@napi
List<Uint8List> failingBytes(int length) => _FailingByteList(length);

@napi
Future<List<Uint8List>> failingBytesAsync(int length) async =>
    failingBytes(length);

final class _FailingMap extends MapBase<String, int> {
  _FailingMap(this.error);
  final Object error;
  @override
  Iterable<String> get keys => const ['bad'];
  @override
  int? operator [](Object? key) => throw error;
  @override
  void operator []=(String key, int value) => throw UnimplementedError();
  @override
  int? remove(Object? key) => throw UnimplementedError();
  @override
  void clear() => throw UnimplementedError();
}

@napi
List<int> formatterRangeList() => _FailingList(RangeError(_BadMessage()));

@napi
Future<List<int>> formatterRangeListAsync() async => formatterRangeList();

@napi
List<int> formatterTypeList() => _FailingList(_BadTypeError());

@napi
Future<List<int>> formatterTypeListAsync() async => formatterTypeList();

@napi
Map<String, int> formatterRangeMap() => _FailingMap(RangeError(_BadMessage()));

@napi
Future<Map<String, int>> formatterRangeMapAsync() async => formatterRangeMap();

@napi
Map<String, int> formatterTypeMap() => _FailingMap(_BadTypeError());

@napi
Future<Map<String, int>> formatterTypeMapAsync() async => formatterTypeMap();
