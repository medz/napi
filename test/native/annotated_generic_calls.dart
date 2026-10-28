import 'package:napi/napi.dart';

@NAPI()
class Box<T> {
  @NAPI()
  Box(this.value);

  @NAPI()
  T value;
}

@NAPI.object()
class Amount {
  @NAPI()
  Amount({required String value}) : value = int.parse(value);

  @NAPI()
  final int value;
}

@NAPI()
Box<double> doubleBox() => Box(1.0);

@NAPI()
Box<int> intBox() => Box(1);

@NAPI()
Box<List<int>> listBox() => Box([1]);

@NAPI()
Box<Amount> amountBox() => Box(Amount(value: '1'));

@NAPI()
Box<Future<int>> futureBox() => Box(Future.value(1));

@NAPI()
Box<Future<Amount>> futureAmountBox() => Box(Future.value(Amount(value: '1')));

@NAPI()
Box<Future<int>?> nullableFutureBox() => Box(null);

@NAPI()
T writeBox<T>(Box<T> box, T value) => box.value = value;

@NAPI()
String boxType<T>(Box<T> box) => '$T';

@NAPI()
Box<T> rebox<T>(Box<T> box, T value) => Box(value);

@NAPI()
void exchange<T>(Box<T> first, Box<T> second) {
  final previous = first.value;
  first.value = second.value;
  second.value = previous;
}

@NAPI()
T numeric<T extends num>(Box<T> box, T value) => box.value = value;

@NAPI()
T optionalBox<T>(T value, [Box<T>? box]) {
  if (box != null) box.value = value;
  return value;
}

@NAPI()
Box<T> optionalRebox<T>(T value, [Box<T>? box]) => Box(value);

@NAPI()
T transform<T>(Box<T> box, T Function(T) callback) => callback(box.value);

@NAPI()
Future<T> asynchronous<T>(Box<T> box, Future<T> value) => value;

@NAPI()
List<T> collection<T>(Box<T> box, List<T> values) => values;

@NAPI()
String bounded<T extends num>(T value, [Box<T>? box]) => '$T';

@NAPI()
String sameType<T>([Box<T>? first, Box<T>? second]) => '$T';

@NAPI()
T namedOptional<T>(T value, {Box<T>? box}) => value;

@NAPI()
String defaultBound<T extends U, U>(Box<U> parent, [Box<T>? child]) => '$T/$U';

@NAPI()
T dependent<T extends U, U>(Box<U> parent, Box<T> child, T value) =>
    child.value = value;

@NAPI()
T defaultValue<T extends U, U>(Box<U> parent, T value) => value;

@NAPI.object()
class Readout {
  Readout(this.value);
  @NAPI()
  final int value;
}

@NAPI()
class ReadonlyBox<T> {
  ReadonlyBox(this.value);
  @NAPI()
  final T value;
}

@NAPI()
ReadonlyBox<List<Readout?>> readoutBox() => ReadonlyBox([Readout(42), null]);

@NAPI()
T read<T>(ReadonlyBox<T> box) => box.value;

@NAPI()
T fromInput<T>(ReadonlyBox<T> box, T value) => value;

@NAPI()
T namedBox<T>({required Box<T> box, required T value}) => box.value = value;

@NAPI()
class Pair<K, V> {
  @NAPI()
  Pair(this.key, this.value);

  @NAPI()
  K key;

  @NAPI()
  V value;
}

@NAPI()
Pair<double, Amount> pair() => Pair(1.0, Amount(value: '2'));

@NAPI()
V writePair<K, V>(Pair<K, V> pair, K key, V value) {
  pair.key = key;
  return pair.value = value;
}

@NAPI()
class Service {
  @NAPI()
  int mode = 0;

  @NAPI()
  T update<T>(Box<T> box, T value, {int mode = 1}) {
    this.mode = mode;
    return box.value = value;
  }
}

class CustomService extends Service {
  @override
  T update<T>(Box<T> box, T value, {int mode = 77}) =>
      super.update(box, value, mode: mode);
}

@NAPI()
Service service() => CustomService();
