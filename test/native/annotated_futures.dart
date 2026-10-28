import 'dart:async';
import 'dart:typed_data';

import 'package:napi/napi.dart';

@NAPI()
Future<int> asyncValue(int value) async => value;

@NAPI()
Future<int> echoFuture(Future<int> value) => value;

@NAPI()
Future<int> futureWithOffset(Future<int> value, int offset) async =>
    await value + offset;

@NAPI()
Future<void> completeVoid(Future<void> value) async => await value;

@NAPI()
Future<int?> nullableValue(Future<int?> value) => value;

@NAPI()
Future<int>? nullableFuture([Future<int>? value]) => value;

@NAPI()
Future<Map<String, int>> mapFuture(Future<Map<String, int>> value) => value;

@NAPI()
Future<int> unsafeValue() async => 9007199254740992;

@NAPI()
Future<Never> failNever() async => throw StateError('future never');

@NAPI()
Future<int> delayed(int value, [int milliseconds = 2]) =>
    Future.delayed(Duration(milliseconds: milliseconds), () => value);

@NAPI()
Future<int> pending() => Completer<int>().future;

@NAPI()
class AsyncCounter {
  @NAPI()
  AsyncCounter([this.value = 0]);
  @NAPI()
  int value;

  @NAPI()
  Future<int> increment(int step) async => value += step;
  @NAPI()
  Future<int> get doubled async => value * 2;
}

@NAPI()
List<Future<int?>> futureList(List<Future<int?>> values) => values;

@NAPI()
Future<int> applyAsync(int value, Future<int> Function(int) callback) async =>
    await callback(value);

@NAPI()
Future<int> Function(int) multiplyAsync(int factor) =>
    (value) async => value * factor;

@NAPI()
Future<int> passFuture(Future<int> Function(Future<int>) callback) async =>
    await callback(Future.value(7));

@NAPI()
Future<void> notifyAsync(Future<void> Function() callback) async =>
    await callback();

@NAPI()
class Thenable {
  Thenable(this.value);
  int value;

  @NAPI()
  void then(void Function(int) resolve) => resolve(value);
}

@NAPI()
Future<Thenable> thenable(int value) async => Thenable(value);

@NAPI()
Future<int> readThenable(Future<Thenable> value) async => (await value).value;

@NAPI()
Future<Future<int>> nestedFuture() =>
    Future<Future<int>>.syncValue(Future<int>.value(7));

@NAPI()
Future<int> readNested(Future<Future<int>> value) async => await await value;

@NAPI()
Future<int> readDeepNested(Future<Future<Future<int>>> value) async =>
    await await await value;

@NAPI()
Future<Future<int>> echoNested(Future<Future<int>> value) => value;

@NAPI()
Future<bool> nestedMissing(Future<Future<int>?> value) async =>
    await value == null;

@NAPI()
Future<int?> nestedNullableValue(Future<Future<int?>> value) async =>
    await await value;

@NAPI()
Future<void> nestedVoid(Future<Future<void>> value) async => await await value;

@NAPI()
Future<int> nestedCallback(Future<Future<int>> Function() callback) =>
    readNested(callback());

@NAPI()
Future<Uint8List> createBytes(int length) async => Uint8List(length);
