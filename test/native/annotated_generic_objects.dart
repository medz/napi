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
Amount applyAmount(Amount value, Handler<Amount> handler) => handler.run(value);

@NAPI()
Envelope<Handler<Amount>> nestedHandler(Envelope<Handler<Amount>> value) =>
    value;
