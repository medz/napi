import 'package:napi/napi.dart';

const _number = 2 * 3 + 1;
const _label = 'fallback';
const _text = 'a\ud800b\udfffc\$\u0000\u2028\u2029';
const _wide = 9007199254740993;
int _calls = 0;

T _record<T>(T value) {
  _calls++;
  return value;
}

@NAPI()
int argumentCalls() => _calls;

@NAPI()
int? requiredNullable(int? value) => _record(value);

@NAPI()
int optionalNumber([int value = _number]) => _record(value);

@NAPI()
int? optionalNullable([int? value = 11]) => _record(value);

@NAPI()
int? optionalNull([int? value]) => _record(value);

@NAPI()
String optionalValues([
  bool flag = true,
  int count = _number,
  String label = _label,
]) => _record('$flag|$count|$label');

@NAPI()
String optionalText([String value = _text]) => _record(value);

@NAPI()
double optionalDouble([double value = -0.0]) => _record(value);

@NAPI()
double optionalNaN([double value = double.nan]) => _record(value);

@NAPI()
double optionalInfinity([double value = double.infinity]) => _record(value);

@NAPI()
double optionalNegativeInfinity([double value = double.negativeInfinity]) =>
    _record(value);

@NAPI(bigint: true)
int optionalWide([int value = _wide]) => _record(value);

@NAPI()
BigInt? optionalBigInt([BigInt? value]) => _record(value);

@NAPI()
String namedValues(
  int prefix, {
  int count = _number,
  bool flag = true,
  String label = _label,
  int? maybe = 11,
}) => _record('$prefix|$count|$flag|$label|$maybe');

@NAPI()
int? requiredNamed(int prefix, {required int? value, bool flag = true}) =>
    _record(flag ? value : prefix);

@NAPI(bigint: true)
int namedWide({int value = _wide, bool flag = true}) =>
    _record(flag ? value : 0);

@NAPI()
int manyNamed({
  int p00 = 1,
  int p01 = 2,
  int p02 = 3,
  int p03 = 4,
  int p04 = 5,
  int p05 = 6,
  int p06 = 7,
  int p07 = 8,
  int p08 = 9,
  int p09 = 10,
  int p10 = 11,
  int p11 = 12,
  int p12 = 13,
  int p13 = 14,
  int p14 = 15,
  int p15 = 16,
  int p16 = 17,
  int p17 = 18,
  int p18 = 19,
  int p19 = 20,
  int p20 = 21,
  int p21 = 22,
  int p22 = 23,
  int p23 = 24,
  int p24 = 25,
  int p25 = 26,
  int p26 = 27,
  int p27 = 28,
  int p28 = 29,
  int p29 = 30,
  int p30 = 31,
  int p31 = 32,
  int p32 = 33,
  int p33 = 34,
  int p34 = 35,
}) => _record(
  p00 +
      p01 +
      p02 +
      p03 +
      p04 +
      p05 +
      p06 +
      p07 +
      p08 +
      p09 +
      p10 +
      p11 +
      p12 +
      p13 +
      p14 +
      p15 +
      p16 +
      p17 +
      p18 +
      p19 +
      p20 +
      p21 +
      p22 +
      p23 +
      p24 +
      p25 +
      p26 +
      p27 +
      p28 +
      p29 +
      p30 +
      p31 +
      p32 +
      p33 +
      p34,
);

@NAPI()
int optionalFailure([bool fail = false]) {
  _calls++;
  if (fail) throw StateError('optional failure');
  return 1;
}

void main() => throw StateError('business main must not run');
