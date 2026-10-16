import 'package:napi/napi.dart' as napi;

// Typedefs must preserve Dart type identity and the selected int policy.
typedef Count = int;
typedef OptionalCount = int?;

int _calls = 0;
int _scalarCalls = 0;

T _record<T>(T value) {
  _scalarCalls++;
  return value;
}

@napi.NAPI()
Count add(Count a, Count b) {
  _calls++;
  return a + b;
}

@napi.NAPI()
int calls() => _calls;
@napi.NAPI()
int scalarCalls() => _scalarCalls;
@napi.NAPI()
int echo(int value) => value;

@napi.NAPI()
bool echoBool(bool value) => _record(value);
@napi.NAPI()
bool negate(bool value) => _record(!value);
@napi.NAPI()
String echoString(String value) => _record(value);
@napi.NAPI()
String reverseString(String value) =>
    _record(String.fromCharCodes(value.codeUnits.reversed));
@napi.NAPI()
int stringLength(String value) => _record(value.length);
@napi.NAPI()
int stringCodeUnitAt(String value, int index) =>
    _record(value.codeUnitAt(index));
@napi.NAPI()
double echoDouble(double value) => _record(value);
@napi.NAPI()
double reciprocal(double value) => _record(1 / value);
@napi.NAPI()
BigInt echoBigInt(BigInt value) => _record(value);
@napi.NAPI()
BigInt addBigInt(BigInt left, BigInt right) => _record(left + right);

@napi.NAPI()
bool? nullableBool(bool? value) => _record(value);
@napi.NAPI()
String? nullableString(String? value) => _record(value);
@napi.NAPI()
double? nullableDouble(double? value) => _record(value);
@napi.NAPI()
OptionalCount nullableInt(OptionalCount value) => _record(value);
@napi.NAPI()
BigInt? nullableBigInt(BigInt? value) => _record(value);

@napi.NAPI(bigint: true)
Count echoWideInt(Count value) => _record(value);
@napi.NAPI(bigint: true)
int addWideInt(int left, int right) => _record(left + right);
@napi.NAPI(bigint: true)
OptionalCount nullableWideInt(OptionalCount value) => _record(value);
// bigint applies only to Dart int, not to other scalar parameters or results.
@napi.NAPI(bigint: true)
int? chooseWideInt(
  bool first,
  int? left,
  int? right,
  String label,
  double score,
) {
  _scalarCalls++;
  if (label.isEmpty || score.isNaN) return null;
  return first ? left : right;
}

@napi.NAPI(bigint: true)
BigInt promoteWideInt(int value) => _record(BigInt.from(value));
@napi.NAPI(bigint: true)
double wideIntToDouble(int value) => _record(value.toDouble());

@napi.NAPI()
int unsafeIntResult(bool negative) =>
    _record(negative ? -9007199254740992 : 9007199254740992);
@napi.NAPI()
int? unsafeNullableIntResult(bool negative) =>
    _record(negative ? -9007199254740992 : 9007199254740992);

// Strict-mode JavaScript binding restrictions do not apply to Dart names.
@napi.NAPI(name: 'evaluate')
int eval(int arguments) => arguments + 1;
@napi.NAPI(name: 'argumentCount')
int arguments(int eval) => eval + 2;
@napi.NAPI()
int fail(int mode) {
  if (mode == 1) throw StateError('intentional failure');
  if (mode == 2) throw _Unprintable();
  return mode;
}

class _Unprintable {
  @override
  String toString() => throw StateError('description also failed');
}

void main() => throw StateError('business main must not run');
