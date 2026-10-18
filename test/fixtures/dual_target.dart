import 'dart:async';

import 'package:napi/napi.dart';

int _calls = 0;
int _cleanups = 0;
final _singleton = Counter(7);

@NAPI()
int calls() => _calls;
@NAPI()
int cleanups() => _cleanups;
@NAPI()
void reset() {
  _calls = 0;
}

@NAPI()
int add(int a, [int b = 2]) {
  _calls++;
  return a + b;
}

@NAPI()
String format(String value, {String suffix = '雪'}) => value + suffix;
@NAPI()
Counter identity(Counter value) => value;
@NAPI()
Counter singleton() => _singleton;
@NAPI()
int invoke(int Function(int) callback, int value) => callback(value);
@NAPI()
Future<int> later(int value) async => value + 1;
@NAPI()
Stream<int> sequence(int value) async* {
  yield value;
  yield value + 1;
}

@NAPI()
void fail() => throw StateError('dual-failure');

@NAPI()
class Counter {
  int value;
  Counter([this.value = 1]);
  Counter.seed(this.value);
  int increment([int amount = 1]) => value += amount;
}

@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Resource {
  final int value;
  Resource(this.value);
  Future<int> read([int milliseconds = 2]) =>
      Future.delayed(Duration(milliseconds: milliseconds), () => value);
  Stream<int> values() async* {
    yield value;
    yield value + 1;
  }

  void close() {
    _cleanups++;
  }
}
