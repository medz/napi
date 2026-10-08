import 'dart:typed_data';

import 'package:napi/napi.dart';

@napi
bool identityBool(bool value) => value;

@napi
int identityInt(int then) => then;

@napi
double identityDouble(double value) => value;

@napi
String identityString(String value) => value;

@napi
Uint8List identityBytes(Uint8List value) => value;

@napi
Uint8List incrementFirst(Uint8List value) {
  if (value.isNotEmpty) value[0] = (value[0] + 1) & 0xff;
  return value;
}

@napi
bool? nullableBool(bool? value) => value;

@napi
int? nullableInt(int? value) => value;

@napi
double? nullableDouble(double? value) => value;

@napi
String? nullableString(String? value) => value;

@napi
Uint8List? nullableBytes(Uint8List? value) => value;

@napi
int oversizedInt() => 9007199254740992;

@napi
int throwError(String message) => throw StateError(message);

@napi
int throwRange() => throw RangeError('range failure');

@napi
int throwArgument() => throw ArgumentError('argument failure');

@napi
String readFile(String value) => 'Dart readFile: $value';

@napi
String response(String value) => 'Dart response: $value';

@napi
int instantiate(int value) => value + 1;

@napi
String $napiReadFile(String value) => 'Dart dollar: $value';

@napi
String fetch(String value) => 'Dart fetch: $value';

@napi
// ignore: non_constant_identifier_names
int URL() => 42;

@napi
// ignore: non_constant_identifier_names
String Error() => 'Dart Error';

var _counter = 0;

@napi
void incrementCounter() {
  _counter++;
}

@napi
int counter() => _counter;
