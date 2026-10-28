import 'dart:typed_data';

import 'package:napi/env.dart';
import 'package:napi/napi.dart';

@NAPI()
T identity<T>(T value) => value;

@NAPI()
T? nullable<T>(T? value) => value;

@NAPI()
(T, U) pair<T, U>(T first, U second) => (first, second);

@NAPI()
class Box<T> {
  @NAPI()
  Box(this.value);

  @NAPI()
  T value;

  @NAPI()
  T replace(T next) {
    final previous = value;
    value = next;
    return previous;
  }

  @NAPI()
  U echo<U>(U value) => value;

  @NAPI()
  List<T> get items => [value];

  @NAPI()
  Map<String, T> get named => {'value': value};

  @NAPI()
  bool get holdsInt => T == int;
}

@NAPI()
Box box = Box<dynamic>(0);

@NAPI()
Box<T> echoBox<T>(Box<T> value) => value;

final _integerBox = Box<int>(7);

@NAPI()
Box<dynamic> wideBox() => _integerBox;

@NAPI()
Box<num> numericBox() => _integerBox;

@NAPI()
Box<int> intBox() => _integerBox;

@NAPI()
Box<int> consumeIntBox(Box<int> value) => value;

@NAPI()
Box<int>? nullableIntBox(Box<int>? value) => value;

@NAPI()
T readBox<T>(Box<T> value) => value.value;

@NAPI()
Box<String?> textBox() => Box<String?>(null);

@NAPI()
Box<Object?> anyBox() => Box<Object?>(null);

@NAPI()
Box<BigInt> bigIntBox() => Box(BigInt.one << 100);

@NAPI()
Box<JsReference<JsObject>> objectBox(JsReference<JsObject> value) => Box(value);

@NAPI()
class LabeledBox<T> extends Box<T> {
  @NAPI()
  LabeledBox(super.value);

  @NAPI()
  String get label => 'labeled';
}

final _labeledBox = LabeledBox<int>(9);

@NAPI()
Box<num> parentBox() => _labeledBox;

@NAPI()
LabeledBox<int> labeledBox() => _labeledBox;

@NAPI()
class AdjustedBox extends Box<int> {
  @NAPI()
  AdjustedBox(super.value);

  @override
  @NAPI()
  int replace(int next, [int adjustment = 0]) =>
      super.replace(next + adjustment);
}

@NAPI()
AdjustedBox adjustedBox() => AdjustedBox(3);

@NAPI()
class ScaledBox<T extends num> extends Box<T> {
  @NAPI()
  ScaledBox(super.value);

  @override
  @NAPI()
  T replace(T next, [bool twice = false]) =>
      super.replace(twice ? (next * 2) as T : next);
}

@NAPI()
Box<double> scaledBox() => ScaledBox<double>(1);

final _listBox = LabeledBox<List<int>>([1, 2]);

@NAPI()
Box<dynamic> wideListBox() => _listBox;

@NAPI()
Box<List<int>> listBox() => _listBox;

@NAPI()
LabeledBox<List<int>> labeledListBox() => _listBox;

@NAPI()
Box<List<int>> consumeListBox(Box<List<int>> value) => value;

@NAPI()
List<int> readListBox(Box<List<int>> value) => value.value;

@NAPI()
Box<Map<String, List<int?>>> mapBox() => Box({
  'items': [1, null],
});

@NAPI()
Box<Set<int>> setBox() => Box({1, 2});

@NAPI()
class RecordBox<T, U> extends Box<(T, {U label})> {
  @NAPI()
  RecordBox(T value, U label) : super((value, label: label));
}

@NAPI()
Box<(int, {String label})> recordBox() => RecordBox<int, String>(1, 'first');

@NAPI()
class PairBox<T> extends Box<(T, T)> {
  @NAPI()
  PairBox(T first, T second) : super((first, second));
}

@NAPI()
Box<(int, int)> pairBox() => PairBox<int>(1, 2);

@NAPI()
Box<List<int>?> nullableListBox() => Box(null);

@NAPI()
Box<List<JsReference<JsObject>>> referenceListBox(
  List<JsReference<JsObject>> values,
) => Box(values);

@NAPI()
Box<DateTime> dateBox() => Box(DateTime.fromMillisecondsSinceEpoch(1000));

@NAPI()
Box<Uint8List> bytesBox() => Box(Uint8List.fromList([1, 2]));

@NAPI()
Box<ByteData> dataBox() => Box(ByteData(4)..setInt32(0, 42, Endian.little));

@NAPI()
Box<Float32x4> vectorBox() => Box(Float32x4(1, 2, 3, 4));

@NAPI()
enum Stage {
  @NAPI()
  pending,
  @NAPI()
  done,
}

@NAPI()
Box<Stage> stageBox() => Box(Stage.pending);

@NAPI()
class FutureBox<T> extends Box<Future<T>> {
  @NAPI()
  FutureBox(super.value);
}

@NAPI()
Box<Future<List<int>>> futureBox() =>
    FutureBox<List<int>>(Future.value([1, 2]));

@NAPI()
Box<Future<void>> doneBox() => Box(Future<void>.value());

typedef IntBoxIdentity = T Function<T extends Box<int>>(T value);

@NAPI()
Box<int> callIntBox(IntBoxIdentity callback) => callback(_integerBox);

@NAPI()
IntBoxIdentity intBoxIdentity() =>
    <T extends Box<int>>(T value) => value;

@NAPI()
List<T> copyList<T>(List<T> values) => values;

@NAPI()
Map<String, T> copyMap<T>(Map<String, T> values) => values;

@NAPI()
T numeric<T extends num>(T value) => value;

@NAPI()
T nullableNumeric<T extends num?>(T value) => value;

@NAPI()
T nonNull<T extends Object>(T value) => value;

@NAPI()
T reference<T extends JsReference<JsObject>>(T value) => value;

@NAPI()
T apply<T>(T value, T Function(T) callback) => callback(value);

class Base<T> {
  @NAPI()
  U echo<U extends T>(U value) => value;
}

@NAPI()
class NumericChild extends Base<num> {
  @NAPI()
  NumericChild();
}

@NAPI()
class GenericNumericChild<U extends num> extends Base<U> {
  @NAPI()
  GenericNumericChild();
}

@NAPI()
class Counter {
  @NAPI()
  Counter(this.value);

  @NAPI()
  int value;
}

@NAPI()
class SpecialCounter extends Counter {
  @NAPI()
  SpecialCounter(super.value);

  @NAPI()
  String get label => 'special';
}

@NAPI()
T boundIdentity<T extends Counter>(T value) => value;

@NAPI()
T nullableBound<T extends Counter?>(T value) => value;

@NAPI()
class CounterBox<T extends Counter> {
  @NAPI()
  CounterBox(this.value);

  @NAPI()
  T value;

  @NAPI()
  U echo<U extends T>(U value) => value;
}

typedef CounterIdentity = T Function<T extends Counter>(T value);
typedef NullableCounterIdentity = T Function<T extends Counter?>(T value);

@NAPI()
bool boundCallback(SpecialCounter value, CounterIdentity callback) =>
    identical(callback<SpecialCounter>(value), value);

@NAPI()
CounterIdentity boundFunction() => boundIdentity;

@NAPI()
CounterIdentity returnBoundCallback(CounterIdentity callback) => callback;

@NAPI()
bool nullableBoundCallback(NullableCounterIdentity callback) =>
    callback<Counter?>(null) == null;

@NAPI.object()
class BoundHandler<T> {
  @NAPI()
  BoundHandler({required this.run});

  @NAPI()
  final U Function<U extends T>(U) run;
}

@NAPI()
bool handleCounter(BoundHandler<Counter> handler, SpecialCounter value) =>
    identical(handler.run<SpecialCounter>(value), value);

@NAPI()
bool handleNullableCounter(BoundHandler<Counter?> handler, Counter? value) =>
    identical(handler.run<Counter?>(value), value);

@NAPI()
BoundHandler<Counter> counterHandler() => BoundHandler(run: boundIdentity);

@NAPI()
Future<SpecialCounter> asyncBoundCallback(
  SpecialCounter value,
  Future<T> Function<T extends Counter>(T) callback,
) => callback<SpecialCounter>(value);

@NAPI()
void registerObject(Env env) {
  env.defineClass<Object>('ObjectWrapper', constructor: (_) => Object());
}

@NAPI()
BoundHandler<Object> objectHandler() => BoundHandler(run: nonNull);
