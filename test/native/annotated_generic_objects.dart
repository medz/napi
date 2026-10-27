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
