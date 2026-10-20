import 'dart:async';

import 'package:napi/napi.dart';

int _calls = 0;
int _cleanups = 0;
final _singleton = Counter(7);

/// A labeled row of copied numbers.
typedef Row = ({String label, List<int> values});

/// Appends a number to the copied row without changing the JavaScript input.
@NAPI()
Row appendRow(Row row) {
  row.values.add(3);
  return row;
}

@NAPI()
int calls() => _calls;
@NAPI()
int cleanups() => _cleanups;
@NAPI()
void reset() {
  _calls = 0;
}

@NAPI()
int add(int a, [int b = 2]) {
  _calls++;
  return a + b;
}

@NAPI()
String format(String value, {String suffix = '雪'}) => value + suffix;
@NAPI()
Counter identity(Counter value) => value;
@NAPI()
Counter singleton() => _singleton;
@NAPI()
int invoke(int Function(int) callback, int value) => callback(value);
@NAPI()
Future<int> later(int value) async => value + 1;
@NAPI()
Stream<int> sequence(int value) async* {
  yield value;
  yield value + 1;
}

@NAPI()
void fail() => throw StateError('dual-failure');

@NAPI()
class Counter {
  int value;
  Counter([this.value = 1]);
  Counter.seed(this.value);
  int increment([int amount = 1]) => value += amount;
}

@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Resource {
  final int value;
  Resource(this.value);
  Future<int> read([int milliseconds = 2]) =>
      Future.delayed(Duration(milliseconds: milliseconds), () => value);
  Stream<int> values() async* {
    yield value;
    yield value + 1;
  }

  void close() {
    _cleanups++;
  }
}

const _empty = <Never>[];
const _mapping = <String, List<int?>>{
  'b': [null, 7],
  'a': [],
};
const _dictionaries = <Dictionary<int>>[Dictionary<int>(<String, Never>{})];
const _record = (<Never>[], label: 'a\ud800b\udfff\$');
const _numbers = <double>[
  1,
  -0.0,
  double.nan,
  -double.nan,
  double.infinity,
  double.negativeInfinity,
];

@NAPI()
bool structuralDefaults([
  List<int> empty = _empty,
  Map<String, List<int?>> mapping = _mapping,
  List<Dictionary<int>> dictionaries = _dictionaries,
  (List<int>, {String label}) record = _record,
]) {
  _calls++;
  return identical(empty, _empty) &&
      identical(mapping, _mapping) &&
      mapping.keys.join() == 'ba' &&
      identical(dictionaries, _dictionaries) &&
      identical(dictionaries.single, _dictionaries.single) &&
      identical(record.$1, _record.$1) &&
      record.label == _record.label;
}

@NAPI()
bool namedDefaults({
  List<double> numbers = _numbers,
  List<int> wide = const [9007199254740993],
}) =>
    identical(numbers, _numbers) &&
    numbers[1].isNegative &&
    identical(wide, const <int>[9007199254740993]);

@NAPI()
class DefaultBase {
  final bool original;
  DefaultBase([List<int> value = _empty]) : original = identical(value, _empty);
  DefaultBase.named({List<int> value = _empty})
    : original = identical(value, _empty);
  DefaultBase.object([DefaultToken value = _token])
    : original = identical(value, _token);
  DefaultBase.namedObject({DefaultToken value = _token})
    : original = identical(value, _token);
  bool check({List<int> value = _empty}) => identical(value, _empty);
  bool checkObject({DefaultToken value = _token}) => identical(value, _token);
  Future<bool> later([List<int> value = _empty]) async =>
      identical(value, _empty);
  Stream<bool> sequence([List<int> value = _empty]) async* {
    yield identical(value, _empty);
  }

  Future<bool> laterObject([DefaultValue value = _value]) async =>
      identical(value, _value);
  Stream<bool> sequenceObject([DefaultToken value = _token]) async* {
    yield identical(value, _token);
  }

  List<int> snapshot([List<int> value = const [1, 2]]) {
    try {
      value[0] = 3;
    } on UnsupportedError {
      return value;
    }
    throw StateError('Default must stay const');
  }
}

@NAPI()
class DefaultChild extends DefaultBase {
  DefaultChild();
  @override
  bool check({List<int> value = const [7]}) => identical(value, _empty);
}

@NAPI()
class DefaultToken {
  final int value;
  const DefaultToken([this.value = 7]);
}

@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new')
class DefaultValue {
  final DefaultToken token;
  final int value;
  const DefaultValue({this.token = _token, this.value = 9});
}

class DefaultValueChild extends DefaultValue {
  const DefaultValueChild();
}

class DefaultBox<T> {
  final T value;
  const DefaultBox(this.value);
}

@NAPI()
typedef DefaultIntBox = DefaultBox<int>;

abstract class Projection<T> {
  const factory Projection(T value) = _DefaultProjection<T, int>;
  T get value;
}

class _DefaultProjection<T, U> implements Projection<T> {
  @override
  final T value;
  const _DefaultProjection(this.value);
}

@NAPI()
typedef DefaultProjection = Projection<int>;

const _token = DefaultToken();
const _value = DefaultValue();
const _objectList = <DefaultValueChild>[DefaultValueChild()];
const _objectMap = <String, DefaultToken>{'token': _token};
const _objectDictionary = Dictionary<DefaultValue>({'value': _value});
const _objectRecord = (token: _token, value: _value);
const _objectBox = DefaultIntBox(13);
const _projection = DefaultProjection(17);

@NAPI()
bool objectDefaults([
  DefaultToken token = _token,
  DefaultValue value = _value,
  List<DefaultValue> values = _objectList,
  Map<String, DefaultToken> mapping = _objectMap,
  Dictionary<DefaultValue> dictionary = _objectDictionary,
  ({DefaultToken token, DefaultValue value}) record = _objectRecord,
]) {
  _calls++;
  return identical(token, _token) &&
      identical(value, _value) &&
      identical(values, _objectList) &&
      identical(mapping, _objectMap) &&
      identical(dictionary, _objectDictionary) &&
      identical(record.token, _token) &&
      identical(record.value, _value);
}

@NAPI()
DefaultToken objectDefaultToken([DefaultToken token = _token]) => token;
@NAPI()
int objectDefaultAfter([DefaultToken token = _token, int after = 3]) =>
    token.value + after;
@NAPI()
bool namedObjectDefault({DefaultToken? token = _token}) =>
    identical(token, _token);
@NAPI()
DefaultValue objectDefaultValue([DefaultValue value = _value]) => value;
@NAPI()
bool valueFieldDefault(DefaultValue value) => identical(value.token, _token);
@NAPI()
bool genericObjectDefault([DefaultIntBox value = _objectBox]) =>
    identical(value, _objectBox);
@NAPI()
bool factoryObjectDefault([DefaultProjection value = _projection]) =>
    identical(value, _projection);
