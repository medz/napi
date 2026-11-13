import 'package:napi/napi.dart';

final _events = <String>[];
Iterable<int>? _saved;

@NAPI()
List<String> events() {
  final result = _events.toList();
  _events.clear();
  return result;
}

@NAPI()
Iterable<int> sequence([int count = 3]) sync* {
  _events.add('start');
  try {
    for (var i = 0; i < count; ++i) {
      yield i;
    }
  } finally {
    _events.add('close');
  }
}

@NAPI()
Iterable<int> nested() sync* {
  try {
    yield* sequence();
  } finally {
    _events.add('outer');
    yield 42;
    _events.add('finished');
  }
}

@NAPI()
Iterable<int> delegate(Iterable<int> values) sync* {
  try {
    yield* values;
  } finally {
    _events.add('delegate:close');
  }
}

@NAPI()
Iterable<int> unsafe() sync* {
  try {
    yield 9007199254740992;
  } finally {
    _events.add('unsafe:close');
  }
}

@NAPI()
Iterable<int> reentrant(void Function() action) sync* {
  try {
    action();
    yield 1;
  } finally {
    _events.add('reentrant:close');
  }
}

@NAPI()
int first(Iterable<int> values) => values.first;

@NAPI()
Future<int> delayedFirst(Iterable<int> values) async {
  for (final value in values) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
    return value;
  }
  return -1;
}

@NAPI()
int stop(Iterable<int> values) {
  for (final value in values) {
    if (value == 0) break;
    return value;
  }
  return -1;
}

@NAPI()
void fail(Iterable<int> values) {
  for (final _ in values) {
    throw StateError('body failed');
  }
}

@NAPI()
List<int> take(Iterable<int> values, int count) =>
    values.map((value) => value * 2).take(count).toList();

@NAPI()
List<String> strings(Iterable<String> values) => values.toList();

@NAPI()
void save(Iterable<int> values) => _saved = values;

@NAPI()
int savedFirst() => _saved!.first;

@NAPI()
void clear() => _saved = null;

@NAPI()
Iterable<T> echo<T>(Iterable<T> values) => values;

@NAPI()
Iterable<int> callback(Iterable<int> Function(Iterable<int>) transform) =>
    transform(sequence());

@NAPI.object()
class Point {
  @NAPI()
  Point(this.x);
  @NAPI()
  final int x;
}

@NAPI()
Iterable<Point> points(Iterable<Point> values) sync* {
  for (final value in values) {
    yield Point(value.x + 1);
  }
}

@NAPI.object()
class Amount {
  @NAPI()
  Amount(String value) : value = int.parse(value);
  @NAPI()
  final int value;
}

@NAPI()
Iterable<Amount> amounts(Iterable<Amount> values) => values;

@NAPI()
class Box<T> {
  @NAPI()
  Box(this.value);
  @NAPI()
  T value;
}

@NAPI()
Iterable<Amount> boxed(void Function<T>(Box<T>) action) {
  final box = Box<Iterable<Amount>>([Amount('3')]);
  action<Iterable<Amount>>(box);
  return box.value;
}

@NAPI()
Iterable<int>? nullable([Iterable<int>? values]) => values;

@NAPI()
Future<Iterable<int>> later() async => sequence();
