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
}

@NAPI()
Box box = Box<dynamic>(0);

@NAPI()
Box<T> echoBox<T>(Box<T> value) => value;

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
