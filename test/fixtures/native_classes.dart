import 'dart:io';
import 'dart:math';

import 'package:napi/napi.dart';

@NAPI()
class Counter {
  int _value;
  Counter([int value = 0]) : _value = value;
  // Exercise an explicit accessor pair in generated native bindings.
  // ignore: unnecessary_getters_setters
  int get value => _value;
  set value(int value) => _value = value;
  int increment([int amount = 1]) => _value += amount;
  int named({int amount = 2}) => _value += amount;
  static String label() => 'Dart Counter';
  @NAPI(name: 'doubleValue')
  int twice() => _value * 2;
  @NAPI(exclude: true)
  String hidden() => 'hidden';
}

@NAPI()
class Other {
  final int value;
  Other([this.value = 4]);
}

@NAPI()
int randomValue() => Random.secure().nextInt(1024);
@NAPI()
String executable() => Platform.executable;

void main() => throw StateError('Business main must not run');

// Public names must not collide with generated loader bindings or globals.
@NAPI(name: 'createRequire')
int exportRequire() => 1;
@NAPI(name: 'bindings')
int exportBindings() => 2;
@NAPI(name: 'globalThis')
int exportGlobal() => 3;
@NAPI(name: 'URL')
int exportUrl() => 4;
