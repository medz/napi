import 'package:napi/napi.dart';

T _sum<T extends num>(T value, {T? extra, int multiplier = 7}) =>
    ((value + (extra ?? 0)) * multiplier) as T;

String _typeName<T>() => T == int
    ? 'int'
    : T == double
    ? 'double'
    : 'other';

int _default<T>(T value, [int count = 11]) => T == int ? count : -count;

T? _optional<T>([T? value]) => value;

T _identity<T>(T value) => value;

Future<T> _later<T>(T value) async => value;

typedef IntegerDefault = int Function(int value, [int count]);
typedef CallableRecord = ({int value, String? label});

@NAPI()
const sumIntegers = _sum<int>;

@NAPI()
const sumDoubles = _sum<double>;

@NAPI(bigint: true)
const sumBigints = _sum<int>;

@NAPI()
const intTypeName = _typeName<int>;

@NAPI()
const doubleTypeName = _typeName<double>;

@NAPI()
const IntegerDefault typedDefault = _default<int>;

@NAPI()
const nullableInteger = _optional<int>;

@NAPI()
const recordIdentity = _identity<CallableRecord>;

@NAPI()
const nestedIdentity = _identity<List<Map<String, int?>>>;

@NAPI()
const laterInteger = _later<int>;

class CallableUtility {
  static T read<T>(T value, [int count = 19]) =>
      (value is num ? value * count : value) as T;
}
