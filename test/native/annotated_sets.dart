import 'package:napi/napi.dart';

Set<int>? _last;

@NAPI()
Set<int> echoInts(Set<int> values) => _last = values;

@NAPI()
Set<int> lastInts() => _last!;

@NAPI()
List<Set<int?>?> echoNested(List<Set<int?>?> values) => values;

@NAPI()
Set<DateTime> echoDates(Set<DateTime> values) => values;

@NAPI()
Set<double> specialNumbers() {
  final values = <double>{};
  values.add(-0.0);
  values.add(0.0);
  values.add(double.nan);
  values.add(double.nan);
  return values;
}

@NAPI()
class Key {
  @NAPI()
  Key(this.value, [this.failure]);

  @NAPI()
  final int value;
  final Object? failure;

  @override
  int get hashCode {
    if (failure != null) throw JsException(failure);
    return value.hashCode;
  }

  @override
  bool operator ==(Object other) => identical(this, other);
}

@NAPI()
Set<Key> echoKeys(Set<Key> values) => values;

@NAPI()
Set<JsReference<JsObject>> echoObjects(Set<JsReference<JsObject>> values) =>
    values;

@NAPI()
Set<int> Function(Set<int>) bounceSet(Set<int> Function(Set<int>) callback) =>
    callback;
