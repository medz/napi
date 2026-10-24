import 'dart:typed_data';

import 'package:napi/napi.dart';

@NAPI()
int add(int left, int right) => left + right;

@NAPI()
class Counter {
  Counter([this.value = 0]);
  int value;
  int increment([int amount = 1]) => value += amount;
}

@NAPI()
Uint8List copyBytes(Uint8List bytes) {
  if (bytes.isNotEmpty) bytes[0] ^= 1;
  return bytes;
}

@NAPI()
SharedBytes sharedBytes(SharedBytes bytes) {
  if (bytes.length != 0) bytes[0] ^= 1;
  return bytes;
}

@NAPI()
SharedBytes allocate(int size) => SharedBytes.allocate(size);
