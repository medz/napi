import 'dart:typed_data';

import 'package:napi/napi.dart';
import 'package:napi/src/_internal/annotations.dart';

@NAPI()
class Versioned {
  @Available(napi: 10)
  int get value => 1;

  @Available(napi: 6)
  set value(int next) {}
}

@NAPI()
class Counter {
  Counter([this.value = 0]);

  int value;
}

const _defaultFields = <String, List<int?>>{
  'default': [1, null],
};

@NAPI()
class FieldMap {
  FieldMap([this.values = _defaultFields]);

  Map<String, List<int?>> values;
  Map<String, int?>? optional;
}

@NAPI()
List<List<int?>> nestedLists(List<List<int?>> values) => values;

@NAPI()
Map<String, List<int?>> echoMap(Map<String, List<int?>> values) => values;

@NAPI()
List<Counter?> echoCounters(List<Counter?> values) => values;

@NAPI()
List<int> byteValues() => Uint8List.fromList([1, 2]);

@NAPI()
Int8List echoInt8(Int8List values) => values;

@NAPI()
Uint8List echoUint8(Uint8List values) => values;

@NAPI()
Uint8ClampedList echoUint8Clamped(Uint8ClampedList values) => values;

@NAPI()
Int16List echoInt16(Int16List values) => values;

@NAPI()
Uint16List echoUint16(Uint16List values) => values;

@NAPI()
Int32List echoInt32(Int32List values) => values;

@NAPI()
Uint32List echoUint32(Uint32List values) => values;

@NAPI()
Int64List echoInt64(Int64List values) => values;

@NAPI()
Uint64List echoUint64(Uint64List values) => values;

@NAPI()
Float32List echoFloat32(Float32List values) => values;

@NAPI()
Float64List echoFloat64(Float64List values) => values;

Uint8List _savedBytes = Uint8List(0);

@NAPI()
Uint8List saveBytes(Uint8List values) => _savedBytes = values;

@NAPI()
Uint8List savedBytes() => _savedBytes;

@NAPI()
void changeSavedByte(int index, int value) {
  _savedBytes[index] = value;
}
