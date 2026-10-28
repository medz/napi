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
  Box.named(this.value);

  @NAPI()
  factory Box.from(T value) => Box(value);

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

@NAPI()
Box<T> wrapBox<T>(T value) => Box(value);

@NAPI()
Box<T> rebox<T>(Box<T> source, T value) => Box(value);

@NAPI()
Box<T> pickBox<T>(List<Box<T>> boxes) => boxes.first;

@NAPI()
Box<T> pickCallbackBox<T>(Box<T> Function() read) => read();

@NAPI()
class Related<T extends U, U> {
  @NAPI()
  Related(this.value);

  @NAPI()
  T value;
}

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

@NAPI()
FutureBox<Future<int>> nestedFutureBox() =>
    FutureBox<Future<int>>(Future.syncValue(Future.value(7)));

@NAPI()
Box<Future<Future<Amount>>> nestedAmountBox() =>
    Box(Future.syncValue(Future.value(Amount(value: '2'))));

@NAPI()
Box<Future<Future<int>?>> nullableNestedBox() => Box(Future.value(null));

@NAPI()
Future<bool> nestedBoxMissing(Box<Future<Future<int>?>> box) async =>
    await box.value == null;

@NAPI()
class CallbackBox<T> extends Box<T Function(num, [int?])> {
  @NAPI()
  CallbackBox(super.value);

  @NAPI()
  T call(int argument) => value(argument);
}

@NAPI()
Box<int Function(int)> callbackBox() =>
    CallbackBox<int>((value, [step = 1]) => value.toInt() + (step ?? 0));

@NAPI()
class NamedCallbackBox<T>
    extends Box<T Function({required num value, int? step})> {
  @NAPI()
  NamedCallbackBox(super.value);

  @NAPI()
  T call(int argument) => value(value: argument);
}

@NAPI()
Box<int Function({required int value})> namedCallbackBox() =>
    NamedCallbackBox<int>(
      ({required value, step = 1}) => value.toInt() + (step ?? 0),
    );

@NAPI()
Box<int Function(int, [int?])> optionalCallbackBox() =>
    Box((value, [step = 5]) => value + (step ?? 0));

@NAPI()
Box<Future<List<int>> Function(List<int>)> asyncCallbackBox() =>
    Box((values) async => [...values, 3]);

@NAPI()
Future<List<int>> callAsyncCallback(
  Box<Future<List<int>> Function(List<int>)> box,
  List<int> values,
) => box.value(values);

@NAPI()
Box<int Function(int)?> nullableCallbackBox() => Box(null);

@NAPI()
Box<List<int Function(int)>> callbackListBox() => Box([(value) => value + 1]);

@NAPI()
Box<void Function()> eventBox() => Box(() {});

@NAPI()
void callEvent(Box<void Function()> box) => box.value();

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

  @NAPI()
  int get then => 42;
}

final _boundCounter = SpecialCounter(7);
final _boundBox = Box<Counter>(_boundCounter);

@NAPI()
Box<Counter> boundBox() => _boundBox;

@NAPI()
Box<dynamic> wideBoundBox() => _boundBox;

@NAPI()
Box<SpecialCounter> specialBoundBox() => Box(_boundCounter);

@NAPI()
Box<List<Counter?>> boundListBox(List<Counter?> values) => Box(values);

@NAPI()
Box<Box<int>> nestedBoundBox() => Box(_integerBox);

@NAPI()
Box<Box<dynamic>> recursiveBox() {
  final result = Box<Box<dynamic>>(Box<dynamic>(null));
  result.value = result;
  return result;
}

@NAPI()
Box<Counter Function(Counter)> boundCallbackBox() => Box((value) => value);

@NAPI()
Counter callBoundCallback(Box<Counter Function(Counter)> box, Counter value) =>
    box.value(value);

@NAPI()
Box<Future<Counter>> boundFutureBox() => Box(Future.value(_boundCounter));

@NAPI()
class Tag<T> {
  @NAPI()
  Tag(this.then);

  @NAPI()
  final T then;
}

@NAPI()
class NumericTag<T extends num> extends Tag<T> {
  NumericTag(super.then);
}

@NAPI()
Box<Future<Tag<int>>> taggedFutureBox() => Box(Future.value(NumericTag(42)));

@NAPI()
class HiddenThenCounter extends Counter {
  HiddenThenCounter(super.value);

  void then(void Function(int) resolve) => resolve(value);
}

@NAPI()
Box<Future<Counter>> hiddenThenFutureBox() =>
    Box(Future.value(HiddenThenCounter(11)));

@NAPI()
class Thenable {
  @NAPI()
  Thenable(this.value);

  @NAPI()
  final int value;

  @NAPI()
  void then(void Function(int) resolve) => resolve(value);
}

@NAPI()
Box<Future<Thenable>> thenableBox() => Box(Future.value(Thenable(7)));

@NAPI()
Future<int> readThenableBox(Box<Future<Thenable>> box) async =>
    (await box.value).value;

@NAPI()
class Ticket {
  @NAPI()
  Ticket(this.id);

  @NAPI()
  final int id;
}

@NAPI()
class SettledTicket extends Ticket {
  @NAPI()
  SettledTicket(super.id);

  @NAPI(name: 'then')
  void settle(void Function(String) resolve) => resolve('settled:$id');
}

@NAPI()
class NamedTicket extends Ticket {
  @NAPI()
  NamedTicket(super.id);

  @NAPI()
  int get then => id;
}

@NAPI()
Box<List<Future<Ticket>>> ticketBox() => Box([
  Future.value(Ticket(1)),
  Future.value(SettledTicket(2)),
  Future.value(NamedTicket(3)),
]);

@NAPI()
Future<List<int>> ticketIds(Box<List<Future<Ticket>>> box) async => [
  for (final ticket in box.value) (await ticket).id,
];

@NAPI()
Future<Ticket> ticket(bool settled) async =>
    settled ? SettledTicket(4) : Ticket(5);

@NAPI()
Box<Future<Map<String, void Function(void Function(int))>>> resolverBox(
  bool thenKey,
) => Box(
  Future.value({if (thenKey) 'then': (resolve) => resolve(9), 'other': (_) {}}),
);

@NAPI()
Future<List<String>> resolverKeys(
  Box<Future<Map<String, void Function(void Function(int))>>> box,
) async => (await box.value).keys.toList();

@NAPI()
class Pass {
  @NAPI()
  Pass(this.id);

  @NAPI()
  final int id;
}

@NAPI()
class SettledPass extends Pass {
  @NAPI()
  SettledPass(super.id);

  @NAPI()
  void then(void Function(int) resolve) => resolve(id);
}

@NAPI()
class OpaquePass<T> extends Pass {
  @NAPI()
  OpaquePass(super.id, this.then);

  @NAPI()
  final T then;
}

@NAPI()
Future<Pass> pass(int kind) async => switch (kind) {
  0 => Pass(1),
  1 => SettledPass(2),
  _ => OpaquePass<String>(3, 'plain'),
};

@NAPI()
Future<int> passId(Future<Pass> value) async => (await value).id;

@NAPI()
Box<Future<Map<String, Object?>>> jsonBox() =>
    Box(Future.value({'then': 'plain'}));

@NAPI()
Future<List<String>> jsonKeys(Box<Future<Map<String, Object?>>> box) async =>
    (await box.value).keys.toList();

@NAPI()
class Label<T> {
  @NAPI()
  Label(this.value);

  @NAPI()
  final T value;
}

@NAPI()
class NumberLabel extends Label<int> {
  @NAPI()
  NumberLabel(super.value);

  @NAPI()
  void then(void Function(String) resolve) => resolve('number:$value');
}

@NAPI()
class NestedLabel extends Label<String> {
  @NAPI()
  NestedLabel(super.value);

  @NAPI()
  void then(void Function(Label<List<String>>) resolve) =>
      resolve(Label([value]));
}

@NAPI()
Future<Label<bool>> flagLabel() async => Label(true);

@NAPI()
Future<bool> readFlagLabel(Future<Label<bool>> label) async =>
    (await label).value;

@NAPI()
Future<Label<String>> textLabel(bool nested) async =>
    nested ? NestedLabel('text') : Label('plain');

@NAPI.object()
class Amount {
  @NAPI()
  Amount({required String value}) : value = int.parse(value);

  @NAPI()
  final int value;
}

@NAPI.object()
class Parcel<T> {
  @NAPI()
  Parcel({required this.item});

  @NAPI()
  final T item;
}

@NAPI()
Box<Parcel<Amount>> parcelBox() => Box(Parcel(item: Amount(value: '6')));

final _amountBox = LabeledBox(Amount(value: '7'));

@NAPI()
Box<Amount> amountBox() => _amountBox;

@NAPI()
Box<dynamic> wideAmountBox() => _amountBox;

@NAPI()
LabeledBox<Amount> labeledAmountBox() => _amountBox;

@NAPI()
class AmountBox extends Box<Amount> {
  @NAPI()
  AmountBox(super.value);
}

@NAPI()
Box<List<Amount?>> amountListBox() => Box([Amount(value: '1'), null]);

@NAPI()
Box<(Amount, Amount)> amountPairBox() =>
    PairBox(Amount(value: '1'), Amount(value: '2'));

@NAPI()
Box<Future<Amount>> futureAmountBox() => Box(Future.value(Amount(value: '2')));

@NAPI()
Box<Stream<Amount>> streamAmountBox() => Box(Stream.value(Amount(value: '3')));

@NAPI()
Box<Amount Function(Amount)> amountCallbackBox() => Box((value) => value);

@NAPI()
Amount callAmountCallback(Box<Amount Function(Amount)> box, Amount value) =>
    box.value(value);

@NAPI()
Box<Amount Function(int)> calculatedAmountBox() => CallbackBox<Amount>(
  (value, [step = 1]) => Amount(value: '${value.toInt() + (step ?? 0)}'),
);

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
