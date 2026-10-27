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
