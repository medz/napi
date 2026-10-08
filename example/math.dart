import 'dart:typed_data';

import 'package:napi/napi.dart';

@napi
double add(double a, double b) => a + b;

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
