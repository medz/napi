import 'package:napi/napi.dart';

const _note = 'kept';

@NAPI.object()
class Envelope<T> {
  @NAPI()
  Envelope({required this.value, this.optional, this.note = _note});

  @NAPI()
  final T value;
  @NAPI()
  final T? optional;
  @NAPI()
  final String note;
  @NAPI()
  bool get intType => T == int;
  @NAPI()
  bool get stringType => T == String;
  @NAPI()
  bool get isDoubleType => T == double;
}

@NAPI.object()
class Point {
  @NAPI()
  Point({required String value}) : value = int.parse(value);

  @NAPI()
  final int value;
}

@NAPI.object()
class Amount {
  @NAPI()
  Amount({required String value}) : value = int.parse(value);

  @NAPI()
  final int value;
}

@NAPI.object()
class Handler<T> {
  @NAPI()
  Handler({required this.run});

  @NAPI()
  final T Function(T) run;
}

@NAPI.object()
class FnHolder {
  @NAPI()
  FnHolder({required this.run});

  @NAPI()
  final T Function<T>(T) run;
}

@NAPI.object()
class AsyncFnHolder {
  @NAPI()
  AsyncFnHolder({required this.run});

  @NAPI()
  final Future<T> Function<T>(T) run;
}

@NAPI.object()
class AsyncBoundFnHolder {
  @NAPI()
  AsyncBoundFnHolder({required this.run});

  @NAPI()
  final Future<T> Function<T extends num>(T) run;
}

@NAPI.object()
class Chain {
  @NAPI()
  Chain({required this.next});

  @NAPI()
  final Chain Function() next;
}

@NAPI.object()
class AsyncChain {
  @NAPI()
  AsyncChain({required this.next});

  @NAPI()
  final Future<AsyncChain?> next;
}

@NAPI.object()
class FutureCallbackChain {
  @NAPI()
  FutureCallbackChain({required this.next});

  @NAPI()
  final Future<FutureCallbackChain Function()> next;
}

@NAPI.object()
class ConcreteCycleA {
  @NAPI()
  ConcreteCycleA({required String value, required this.next})
    : value = int.parse(value);

  @NAPI()
  final int value;
  @NAPI()
  final ConcreteCycleB? next;
}

@NAPI.object()
class ConcreteCycleB {
  @NAPI()
  ConcreteCycleB({required this.value, required this.next});

  @NAPI()
  final Future<int> value;
  @NAPI()
  final ConcreteCycleA? next;
}

@NAPI.object()
class Stabilizing<T, U> {
  @NAPI()
  Stabilizing({required T? a, required U? b, required this.next})
    : a = a!,
      b = b!;

  @NAPI()
  final T a;
  @NAPI()
  final U b;
  @NAPI()
  final Stabilizing<T, List<T>>? next;
}

@NAPI.object()
class Alternating<A, B> {
  @NAPI()
  Alternating({
    required B value,
    required this.output,
    required Alternating<A, A>? next,
  });

  @NAPI()
  A get value => output;
  @NAPI()
  final A output;
  @NAPI()
  Alternating<List<B>, B>? get next => null;
}

@NAPI.object()
class BoundHolder<U> {
  @NAPI()
  BoundHolder({required this.run});

  @NAPI()
  final T Function<T extends U>(T) run;
}

@NAPI.object()
class StringInput {
  @NAPI()
  // ignore: prefer_initializing_formals
  StringInput({required String value}) : value = value;

  @NAPI()
  final dynamic value;
}

@NAPI.object()
class ThenableAmount {
  @NAPI()
  ThenableAmount({required String value}) : value = int.parse(value);

  @NAPI()
  final int value;
  @NAPI()
  void Function(void Function(int)) get then =>
      (resolve) => resolve(value);
}

@NAPI.object()
class ThenableRecord {
  @NAPI()
  // ignore: prefer_initializing_formals
  ThenableRecord({required int value}) : _value = value;

  final int _value;
  @NAPI()
  void Function(void Function(({int value}))) get then =>
      (resolve) => resolve((value: _value));
}

@NAPI.object()
class ThenableRecordHolder {
  @NAPI()
  ThenableRecordHolder({required this.future});

  @NAPI()
  final Future<ThenableRecord> future;
}

@NAPI.object()
class ThenableChain {
  @NAPI()
  ThenableChain({required this.then, required this.next});

  @NAPI()
  final void Function(void Function(int)) then;
  @NAPI()
  final Future<ThenableChain?> next;
}

@NAPI.object()
class Readout<T> {
  Readout(this.value);

  @NAPI()
  final T value;
}

@NAPI.object()
class Producer<T> {
  @NAPI()
  Producer({required this.create});

  @NAPI()
  final T Function() create;
}

@NAPI.object()
class Recursive<T> {
  @NAPI()
  Recursive({required this.value, this.next});

  @NAPI()
  final T value;
  @NAPI()
  final Recursive<List<T>>? next;
}

@NAPI()
Envelope<int> echoInt(Envelope<int> value) => value;

@NAPI()
Envelope<String> echoText(Envelope<String> value) => value;

@NAPI()
Envelope<double> echoDouble(Envelope<double> value) => value;

@NAPI()
Envelope<T> echo<T>(Envelope<T> value) => value;

@NAPI()
Envelope<Point> echoPoint(Envelope<Point> value) => value;

@NAPI()
Envelope<int>? nullable([Envelope<int>? value]) => value;

@NAPI()
Envelope<Point> Function(Envelope<Point>) bounce(
  Envelope<Point> Function(Envelope<Point>) callback,
) => callback;

@NAPI()
Future<Map<String, List<Envelope<Point>?>>> groups(
  Future<Map<String, List<Envelope<Point>?>>> value,
) => value;

@NAPI()
Readout<int> readout() => Readout(7);

@NAPI()
Readout<Readout<int>> nestedReadout() => Readout(Readout(7));

@NAPI()
Producer<int> echoIntProducer(Producer<int> value) => value;

@NAPI()
Producer<Point> echoPointProducer(Producer<Point> value) => value;

@NAPI()
Recursive<int> echoRecursive(Recursive<int> value) => value;

@NAPI()
Handler<int> echoIntHandler(Handler<int> value) => value;

@NAPI()
Handler<Amount> echoAmountHandler(Handler<Amount> value) => value;

@NAPI()
Handler<T> echoHandler<T>(Handler<T> value) => value;

@NAPI()
Handler<Amount> nativeHandler() =>
    Handler(run: (value) => Amount(value: '${value.value + 1}'));

@NAPI()
Handler<List<Amount>> nativeListHandler() => Handler(run: (value) => value);

@NAPI()
Handler<Map<String, Amount>> nativeMapHandler() =>
    Handler(run: (value) => value);

@NAPI()
Handler<Amount Function(Amount)> nativeFunctionHandler() =>
    Handler(run: (value) => value);

@NAPI()
Handler<Future<Amount>> nativeFutureHandler() => Handler(run: (value) => value);

@NAPI()
FnHolder echoFnHolder(FnHolder value) => value;

@NAPI()
AsyncFnHolder echoAsyncFnHolder(AsyncFnHolder value) => value;

@NAPI()
Future<int> applyAsyncFnHolder(AsyncFnHolder value, int input) =>
    value.run<int>(input);

@NAPI()
Future<bool> asyncScalarBound(AsyncBoundFnHolder holder) async =>
    (await holder.run<double>(3)).runtimeType == double;

@NAPI()
Chain echoChain(Chain value) => value;

@NAPI()
AsyncChain echoAsyncChain(AsyncChain value) => value;

@NAPI()
FutureCallbackChain echoFutureCallbackChain(FutureCallbackChain value) => value;

@NAPI()
ConcreteCycleA echoConcreteCycle(ConcreteCycleA value) => value;

@NAPI()
Stabilizing<int, String> echoStabilizing(Stabilizing<int, String> value) =>
    value;

@NAPI()
Alternating<int, String> echoAlternating(Alternating<int, String> value) =>
    value;

@NAPI()
int applyFnHolder(FnHolder value, int input) => value.run<int>(input);

@NAPI()
bool scalarBound(BoundHolder<num> holder) =>
    holder.run<double>(3).runtimeType == double;

@NAPI()
Handler<StringInput> nativeStringHandler() => Handler(run: (value) => value);

@NAPI()
Handler<Future<ThenableAmount>> nativeThenableHandler() =>
    Handler(run: (value) => value);

@NAPI()
ThenableRecordHolder echoThenableRecordHolder(ThenableRecordHolder value) =>
    value;

@NAPI()
ThenableChain echoThenableChain(ThenableChain value) => value;

@NAPI()
Amount applyAmount(Amount value, Handler<Amount> handler) => handler.run(value);

@NAPI()
Envelope<Handler<Amount>> nestedHandler(Envelope<Handler<Amount>> value) =>
    value;
