import 'package:napi/napi.dart';

const _privateInt = -7;
const _privateText = '私有\u0000🌍\ud800';
var _remembered = 0;

@NAPI()
bool echoBool(bool value) => value;

@NAPI()
int echoInt(int value) => value;

@NAPI()
double echoDouble(double value) => value;

@NAPI()
num echoNum(num value) => value;

@NAPI()
String echoString(String value) => value;

@NAPI()
BigInt echoBigInt(BigInt value) => value;

@NAPI()
Null echoNull(Null value) => value;

@NAPI()
bool? echoNullableBool(bool? value) => value;

@NAPI()
int? echoNullableInt(int? value) => value;

@NAPI()
double? echoNullableDouble(double? value) => value;

@NAPI()
num? echoNullableNum(num? value) => value;

@NAPI()
String? echoNullableString(String? value) => value;

@NAPI()
BigInt? echoNullableBigInt(BigInt? value) => value;

@NAPI(name: 'renamedAdd')
int addNumbers(int left, int right) => left + right;

@NAPI(name: 'privateValue')
int _privateAnnotated(int value) => value;

@NAPI()
String positionalDefaults(
  int base, [
  int count = _privateInt,
  String label = _privateText,
  int? maybe = _privateInt,
]) => '$base|$count|$label|$maybe';

@NAPI()
String namedDefaults(
  int base, {
  required int count,
  String label = _privateText,
  int? maybe = _privateInt,
}) => '$base|$count|$label|$maybe';

@NAPI()
String optionalNamed({int count = _privateInt, int? maybe = _privateInt}) =>
    '$count|$maybe';

@NAPI()
void remember(int value) {
  _remembered = value;
}

@NAPI()
int readRemembered() => _remembered;

@NAPI()
Never fail() => throw StateError('annotated failure');

int unannotated() => _privateAnnotated(99);
