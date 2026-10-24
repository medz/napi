import 'dart:async';
import 'dart:typed_data';

import 'package:napi/napi.dart';

@NAPI()
class Counter {
  int value;
  Counter([this.value = 0]);
  int increment({int by = 1}) => value += by;
  Counter self() => this;
  Future<int> later() async => value;
}

@NAPI()
T identity<T>(T value) => value;
@NAPI()
Future<T> later<T>(T value) async => value;
@NAPI()
int callback(int value, int Function(int) callback) => callback(value);
@NAPI()
Future<int> asyncCallback(Future<int> Function() callback) => callback();
@NAPI()
List<int> numbers(List<int> values) => values;
@NAPI()
Map<String, int> counts(Map<String, int> values) => values;
@NAPI()
Uint8List bytes(Uint8List value) => value;
@NAPI()
ByteBuffer buffer(ByteBuffer value) => value;
@NAPI()
int shared(SharedBytes value) {
  value[0]++;
  return value[0];
}

@NAPI()
int mapValue(JsMap<String, int> value) => value.get('count') ?? 0;
@NAPI()
int arrayLength(JsArray<int> value) => value.length;
@NAPI()
Future<int> canceled(AbortSignal signal) async {
  final done = Completer<int>();
  final remove = signal.onAbort(() {
    try {
      signal.throwIfAborted();
    } catch (error, stack) {
      done.completeError(error, stack);
    }
  });
  try {
    return await done.future;
  } finally {
    remove();
  }
}

@NAPI()
Stream<int> sequence() async* {
  yield 1;
  yield 2;
}

@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Resource extends Counter {
  Resource();
  void close() {}
}

@NAPI()
Counter resourceAsCounter() => Resource();
