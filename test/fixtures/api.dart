import 'dart:typed_data';

import 'package:napi/napi.dart';

import 'conditional_profile/profile.dart';

typedef Flag = bool;
typedef UserId = int;
typedef Score = double;
typedef Label = String;
typedef Bytes = Uint8List;
typedef MaybeUserId = UserId?;
typedef MaybeBytes = Bytes?;

@napi
Flag identityBool(Flag value) => value;

@napi
UserId identityInt(UserId then) => then;

@napi
Score identityDouble(Score value) => value;

@napi
Label identityString(Label value) => value;

@napi
Bytes identityBytes(Bytes value) => value;

@napi
Uint8List incrementFirst(Uint8List value) {
  if (value.isNotEmpty) value[0] = (value[0] + 1) & 0xff;
  return value;
}

@napi
Flag? nullableBool(Flag? value) => value;

@napi
MaybeUserId nullableInt(MaybeUserId value) => value;

@napi
double? nullableDouble(double? value) => value;

@napi
String? nullableString(String? value) => value;

@napi
MaybeBytes nullableBytes(MaybeBytes value) => value;

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

@napi
double countedAdd(double a, double b) {
  _counter++;
  return a + b;
}

@napi
Profile conditionalProfile(Profile value) => echoProfile(value);

@napi
int wildcardSingle(int _) => 42;

@napi
String wildcardRepeated(int _, String _) => 'ignored';

@napi
String wildcardMixed(int _, int arg0, String _, bool typeof, int arg1) =>
    '$arg0:$typeof:$arg1';
