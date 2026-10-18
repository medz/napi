import 'package:napi/napi.dart';

var _calls = 0;
int? _value;
var _label = '';

// Every selected export returns synchronous void. Non-void exports must not
// hide missing result signatures or converter branches in this module.
@NAPI()
void empty() {}

@NAPI()
void requiredValue(int value) {
  _calls++;
  _value = value;
}

@NAPI()
void optionalValue([int value = 7]) {
  _calls++;
  _value = value;
}

@NAPI()
void namedValue({int value = 11, String label = 'default'}) {
  _calls++;
  _value = value;
  _label = label;
}

@NAPI()
void requiredNamed({required int? value}) {
  _calls++;
  _value = value;
}

@NAPI()
void fail([int value = 0]) {
  _calls++;
  _value = value;
  throw StateError('void-business-error');
}

@NAPI()
void check(int calls, int? value, String label) {
  if (_calls != calls || _value != value || _label != label) {
    throw StateError('Unexpected void state: $_calls / $_value / $_label');
  }
}

@NAPI()
void numbers(List<int> values) {
  _calls++;
  _value = values.fold<int>(0, (sum, value) => sum + value);
}
