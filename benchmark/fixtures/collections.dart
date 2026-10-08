import 'package:napi/napi.dart';

@napi
int answer() => 42;

@napi
List<int> echoList(List<int> values) => values;

@napi
int sumList(List<int> values) {
  var sum = 0;
  for (final value in values) {
    sum += value;
  }
  return sum;
}

@napi
Map<String, String> echoMap(Map<String, String> values) => values;

@napi
Future<List<int>> echoListAsync(List<int> values) async => values;

@napi
Future<Map<String, String>> echoMapAsync(Map<String, String> values) async =>
    values;
