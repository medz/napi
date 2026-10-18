import 'dart:async';

import 'package:napi/napi.dart';

int _calls = 0;
int _cleanups = 0;
final _singleton = Counter(7);

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
  bool check({List<int> value = _empty}) => identical(value, _empty);
  Future<bool> later([List<int> value = _empty]) async =>
      identical(value, _empty);
  Stream<bool> sequence([List<int> value = _empty]) async* {
    yield identical(value, _empty);
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
