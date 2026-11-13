import 'dart:async';

import 'package:napi/napi.dart';

@NAPI()
FutureOr<int> echo(FutureOr<int> value) => value;

@NAPI()
FutureOr<int?> nullable(FutureOr<int?> value) => value;

@NAPI()
FutureOr<int>? optional([FutureOr<int>? value]) => value;

@NAPI()
FutureOr<void> ignored(FutureOr<void> value) => value;

@NAPI()
List<FutureOr<int>> values(List<FutureOr<int>> value) => value;

@NAPI()
FutureOr<int> apply(FutureOr<int> Function(int) callback) => callback(7);

@NAPI()
FutureOr<int> Function(FutureOr<int>) callback() => echo;

@NAPI()
Future<FutureOr<int>?> nested(Future<FutureOr<int>?> value) => value;

@NAPI()
FutureOr<Future<int>> futureValue(FutureOr<Future<int>> value) => value;

@NAPI.object()
class Envelope<T> {
  @NAPI()
  Envelope({required this.value});

  @NAPI()
  final FutureOr<T> value;
}

@NAPI()
Envelope<Future<int>> envelope(Envelope<Future<int>> value) => value;

@NAPI.object()
class Amount {
  @NAPI()
  Amount({required String value}) : value = int.parse(value);

  @NAPI()
  final int value;
}

@NAPI()
FutureOr<Amount> amount(FutureOr<Amount> value) => value;

@NAPI()
Envelope<Amount> amountEnvelope(Envelope<Amount> value) => value;

@NAPI()
class Box<T> {
  Box(this.value);

  @NAPI()
  T value;
}

@NAPI()
Box<FutureOr<int>> box(bool async) => Box(async ? Future.value(3) : 3);

@NAPI()
Future<int> generic(FutureOr<T> Function<T>(FutureOr<T>) callback) async =>
    await callback<int>(4) + await callback<int>(Future.value(5));

@NAPI()
Future<int> boxed(void Function<T>(Box<T>) callback) async {
  final box = Box<FutureOr<List<int>>>(Future.value([9]));
  callback(box);
  return (await box.value).single;
}

typedef Resolve = void Function(void Function(int));

@NAPI.object()
class Thenable {
  @NAPI()
  Thenable({required this.then});

  @NAPI()
  final FutureOr<Resolve> then;
}

@NAPI()
FutureOr<Thenable> thenable(bool async, bool callable) {
  void resolve(void Function(int) done) => done(11);
  final value = Thenable(then: callable ? resolve : Future.value(resolve));
  return async ? Future.value(value) : value;
}

@NAPI()
FutureOr<Thenable> echoThenable(FutureOr<Thenable> value) => value;
