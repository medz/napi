import 'dart:typed_data';

import 'package:napi/napi.dart';

@napi
double add(double a, double b) => a + b;

@napi
Future<double> addLater(double a, double b) async {
  await Future<void>.delayed(const Duration(milliseconds: 1));
  return a + b;
}

@napi
String greet(String name) => 'Hello, $name';

@napi
int checksum(Uint8List bytes) {
  var sum = 0;
  for (final byte in bytes) {
    sum = (sum + byte) & 0xff;
  }
  return sum;
}

@napi
List<int> doubleAll(List<int> values) => [
  for (final value in values) value * 2,
];

@napi
Map<String, String> labels(Map<String, String> values) => {...values};
