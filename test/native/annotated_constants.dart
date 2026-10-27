import 'package:napi/napi.dart';

export 'annotated_constants_exports.dart' show shown;
export 'annotated_constants_exports.dart' hide shown, hidden;

const _initial = 7;

int _add(int value, {int step = 2}) => value + step;

@NAPI()
const int Function(int, {int step}) add = _add;

@NAPI()
const point = Point(3);

@NAPI(name: 'samePoint')
const alias = point;

@NAPI()
const makePoint = Point.new;

@NAPI()
const Null absent = null;

@NAPI()
const snapshot = (
  status: Status.done,
  empty: null,
  items: <int>[1, 2],
  map: <String, int>{'__proto__': 3},
);

@NAPI()
class Point {
  const Point([this.value = _initial]);
  final int value;

  int plus([int amount = 1]) => value + amount;
}

@NAPI()
enum Status { ready, done }

@NAPI()
({Status status, Null empty, List<int> items, Map<String, int> map})
originalSnapshot() => snapshot;
