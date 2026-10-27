import 'dart:async';

import 'package:napi/napi.dart';

@NAPI()
(int, String) echoPair((int, String) value) => value;

@NAPI()
({String text, BigInt value, int? maybe}) echoNamed(
  ({String text, BigInt value, int? maybe}) value,
) => value;

@NAPI()
(int, {int $2, int length}) echoMixed((int, {int $2, int length}) value) =>
    value;

@NAPI()
() echoEmpty(() value) => value;

@NAPI()
(int?, String?)? nullablePair([(int?, String?)? value]) => value;

const _defaultPair = (3, 'private');
const _defaultNamed = (enabled: true, label: 'default');

@NAPI()
(int, String) defaultPair([(int, String) value = _defaultPair]) => value;

@NAPI()
({bool enabled, String label}) defaultNamed({
  ({bool enabled, String label}) value = _defaultNamed,
}) => value;

@NAPI()
class RecordBox {
  @NAPI()
  RecordBox(this.value);
  @NAPI()
  int value;
}

@NAPI()
({RecordBox item, (int, int) point}) echoBoxed(
  ({RecordBox item, (int, int) point}) value,
) => value;

@NAPI()
class RecordHolder {
  @NAPI()
  RecordHolder(this.value);
  @NAPI()
  (int, String) value;

  @NAPI()
  (int, String) replace((int, String) next) {
    final previous = value;
    value = next;
    return previous;
  }
}

@NAPI()
(int, int) transformPair(
  (int, int) value,
  (int, int) Function((int, int)) transform,
) => transform(value);

@NAPI()
(int, int) Function((int, int)) pairSwapper() =>
    (value) => (value.$2, value.$1);

@NAPI()
List<({int number, String? label})> echoRows(
  List<({int number, String? label})> values,
) => values;

@NAPI()
Future<(int, String)> futurePair(Future<(int, String)> value) => value;

@NAPI()
Stream<(int, String)> pairStream((int, String) value) async* {
  yield value;
}

@NAPI()
Future<List<(int, String)>> collectPairs(Stream<(int, String)> values) =>
    values.toList();
