import 'package:napi/napi.dart';

import 'records.dart' as models;

@napi
int answer() => 42;

@napi
List<models.One> echoOneList(List<models.One> values) => values;

@napi
List<models.Four> echoFourList(List<models.Four> values) => values;

@napi
List<models.Sixteen> echoSixteenList(List<models.Sixteen> values) => values;

@napi
Future<List<models.Four>> echoFourListAsync(List<models.Four> values) async =>
    values;

@napi
models.Four normalizeOne(models.Four value) => (
  active: value.active,
  id: value.id,
  name: value.name.trim(),
  score: value.score,
);

@napi
List<models.Four> normalizeFourList(List<models.Four> values) => [
  for (final value in values) normalizeOne(value),
];

@napi
int sumOne(models.Four value) => value.id;

@napi
int sumFourList(List<models.Four> values) {
  var sum = 0;
  for (final value in values) {
    sum += value.id;
  }
  return sum;
}
