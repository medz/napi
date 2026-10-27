import 'package:napi/env.dart';
import 'package:napi/napi.dart';

typedef Id = T Function<T>(T value);
typedef ListId = List<T> Function<T>(List<T> values);
typedef NumericId = T Function<T extends num>(T value);
typedef OptionalId = T Function<T>(T value, {T? fallback});
typedef AsyncId = Future<T> Function<T>({required T value});
typedef First = A Function<A, B>(A first, B second);
typedef Capture = JsReference<JsObject> Function<T>(T value);
typedef NonNullId = T Function<T extends Object>(T value);

@NAPI()
class Counter {
  @NAPI()
  Counter(this.value);

  @NAPI()
  final int value;
}

@NAPI.object()
class Point {
  @NAPI()
  Point({required String value}) : value = int.parse(value);

  @NAPI()
  final int value;
}

class _Payload {
  _Payload(this.value);
  final int value;
}

@NAPI()
Map<String, bool> exercise(Id callback) {
  final integer = callback<int>(7);
  final number = callback<double>(3);
  final text = callback<String>('\ud800中');
  final nullable = callback<int?>(null);
  final big = BigInt.one << 65;
  final bigResult = callback<BigInt>(big);
  final list = [1, 2];
  final listResult = callback<List<int>>(list);
  final objectResult = callback<Object>(list);
  final nullableObjectResult = callback<Object?>(list);
  final dynamicResult = callback<dynamic>(list);
  final recordResult = callback<(int, String)>((1, 'record'));
  final date = DateTime.utc(2024);
  final dateResult = callback<DateTime>(date);
  int function(int value) => value + 1;
  final functionResult = callback<int Function(int)>(function);
  final counter = Counter(9);
  final counterResult = callback<Counter>(counter);
  final point = Point(value: '3');
  final pointResult = callback<Point>(point);
  return {
    'int': integer == 7 && integer.runtimeType == int,
    'double': number == 3 && number.runtimeType == double,
    'string': text == '\ud800中',
    'nullable': nullable == null,
    'bigint': bigResult == big,
    'list': identical(listResult, list),
    'object': identical(objectResult, list),
    'nullableObject': identical(nullableObjectResult, list),
    'dynamic': identical(dynamicResult, list),
    'record': recordResult == (1, 'record'),
    'date': identical(dateResult, date) && dateResult.isUtc,
    'function': identical(functionResult, function) && functionResult(1) == 2,
    'class': identical(counterResult, counter) && counterResult.value == 9,
    'struct': identical(pointResult, point) && pointResult.value == 3,
  };
}

@NAPI()
List<bool> explicitLists(ListId callback) {
  final values = callback<int>([1, 2]);
  final native = [3, 4];
  final nested = callback<List<int>>([native]);
  return [
    values.length == 2 && values[1] == 2,
    identical(nested.single, native),
  ];
}

T _identity<T>(T value) => value;

@NAPI()
Id identity() => _identity;

@NAPI()
Object? origin(Object? value, Id callback) => callback<Object?>(value);

@NAPI()
Object? borrowedOrigin(Env env, JsReference<JsObject> value, Id callback) =>
    env.withScope(() => callback<Object?>(value.value));

@NAPI()
Future<bool> asyncNative(AsyncId callback) async {
  final value = [1, 2];
  return identical(await callback<List<int>>(value: value), value);
}

@NAPI()
Future<Object?> asyncOrigin(Object? value, AsyncId callback) =>
    callback<Object?>(value: value);

@NAPI()
bool independent(First first, Capture capture) {
  final value = [1, 2];
  final reference = capture<List<int>>(value);
  try {
    return identical(first<List<int>, Object?>(value, reference), value);
  } finally {
    reference.dispose();
  }
}

@NAPI()
T shadow<T>(T value, Id callback) => callback<T>(value);

@NAPI()
int nested(Id Function(Id) callback) => callback(_identity)<int>(7);

@NAPI()
List<bool> numeric(NumericId callback) => [
  callback<int>(7).runtimeType == int,
  callback<double>(3).runtimeType == double,
];

T _numeric<T extends num>(T value) => value;

@NAPI()
NumericId numericIdentity() => _numeric;

T _nonNull<T extends Object>(T value) => value;

@NAPI()
NonNullId nonNullIdentity() => _nonNull;

@NAPI()
class Forward<T extends U, U extends num> {
  @NAPI()
  Forward(this.value);

  @NAPI()
  final T value;
}

@NAPI()
List<bool> borrowed(Env env, Id callback) => env.withScope(() {
  final object = env.object()..defineValue('value', 7);
  final returnedObject = callback<JsObject>(object);
  final function = env.function('read', (_) => 9);
  final returnedFunction = callback<JsFunction>(function);
  final symbol = env.symbol('scope');
  final returnedSymbol = callback<JsSymbol>(symbol);
  final isSame = env.global.get<JsObject>('Object').get<JsFunction>('is');
  return [
    returnedObject.get<int>('value') == 7,
    returnedFunction.call([]) == 9,
    isSame.call([symbol, returnedSymbol]) == true,
  ];
});

@NAPI()
List<int> optionalCalls(OptionalId callback) => [
  callback<int>(1),
  callback<int>(2, fallback: 9),
];

T _fallback<T>(T value, {T? fallback}) => fallback ?? value;

@NAPI()
OptionalId fallbackIdentity() => _fallback;

@NAPI()
bool counterRoundtrip(Counter value, Id callback) =>
    identical(callback<Counter>(value), value);

@NAPI()
bool capture(Id callback) {
  final value = _Payload(17);
  return identical(callback<_Payload>(value), value);
}

@NAPI()
Future<int> readCaptured(Id callback) async {
  await Future<void>.delayed(Duration.zero);
  return callback<_Payload>(_Payload(99)).value;
}
