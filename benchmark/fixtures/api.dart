import 'dart:typed_data';

import 'package:napi/napi.dart';

@napi
double add(double a, double b) => a + b;

@napi
int identityInt(int value) => value;

@napi
String echoString(String value) => value;

@napi
int stringLength(String value) => value.length;

@napi
Uint8List echoBytes(Uint8List value) => value;

@napi
int sumBytes(Uint8List value) {
  var sum = 0;
  for (final byte in value) {
    sum += byte;
  }
  return sum;
}

@napi
int fail() => throw StateError('benchmark failure');

@napi
Future<double> addAsync(double a, double b) async => add(a, b);

@napi
Future<String> echoStringAsync(String value) async => echoString(value);

@napi
Future<Uint8List> echoBytesAsync(Uint8List value) async => echoBytes(value);

@napi
Future<int> failAsync() async => fail();
