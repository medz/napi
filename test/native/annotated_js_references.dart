import 'dart:async';

import 'package:napi/napi.dart';

Object? _saved;

@NAPI()
void saveValue(Object? value) {
  clearValue();
  _saved = value;
}

@NAPI()
Object? savedValue() => _saved;

@NAPI()
Future<Object?> savedLater() async {
  await Future<void>.delayed(Duration.zero);
  return _saved;
}

@NAPI()
void clearValue() {
  final previous = _saved;
  _saved = null;
  if (previous is JsReference) previous.dispose();
}

@NAPI()
JsReference<JsObject> echoObject(JsReference<JsObject> value) => value;

@NAPI()
JsReference<JsFunction> echoFunction(JsReference<JsFunction> value) => value;

@NAPI()
JsReference<JsSymbol> echoSymbol(JsReference<JsSymbol> value) => value;

@NAPI()
JsReference<JsObject>? optionalObject([JsReference<JsObject>? value]) => value;

@NAPI()
JsReference<JsObject> disposedObject(JsReference<JsObject> value) {
  value.dispose();
  return value;
}

@NAPI()
Object? echoValue(Object? value) => value;

@NAPI()
Object echoNonNull(Object value) => value;

@NAPI()
dynamic echoDynamic(dynamic value) => value;

@NAPI()
JsUndefined echoUndefined(JsUndefined value) => value;

@NAPI()
JsUndefined? optionalUndefined([JsUndefined? value]) => value;

const _missing = Object();

@NAPI()
String presence([Object? value = _missing]) => identical(value, _missing)
    ? 'missing'
    : identical(value, undefined)
    ? 'undefined'
    : value == null
    ? 'null'
    : 'value';

@NAPI()
List<Object?> echoValues(List<Object?> values) => values;

@NAPI()
List<JsReference<JsSymbol>> echoSymbols(List<JsReference<JsSymbol>> values) =>
    values;

@NAPI()
Object? applyValue(Object? value, Object? Function(Object?) callback) =>
    callback(value);

@NAPI()
Stream<JsReference<JsSymbol>> symbolStream(JsReference<JsSymbol> value) async* {
  yield value;
}

class _Hidden {}

@NAPI()
Object? dartList() => <int>[1];

@NAPI()
Object? dartRecord() => (1, 'Dart');

@NAPI()
Object? dartClass() => _Hidden();
