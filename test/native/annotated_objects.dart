import 'dart:async';

import 'package:napi/napi.dart';

int _nextSerial = 0;
const _defaultNote = 'kept';

@NAPI.object()
class Point {
  @NAPI()
  Point.parse({
    required String value,
    this.label = 'default',
    this.note = _defaultNote,
    this.next,
    this.child,
  }) : _value = int.parse(value);

  final int _value;

  @NAPI()
  int get value => _value;

  @NAPI(name: 'title')
  final String label;

  @NAPI()
  final String? note;

  @NAPI()
  final Point? next;

  @NAPI()
  final PointInput? child;

  @NAPI()
  final int serial = _nextSerial++;
}

@NAPI()
class PointInput {
  @NAPI()
  PointInput(this.value);

  @NAPI()
  final int value;
}

@NAPI.object()
class Offset {
  @NAPI()
  Offset([this.x = 3, this.y = 4]);

  @NAPI()
  final int x;

  @NAPI()
  final int y;
}

@NAPI.object()
class Readout {
  Readout(this.value);

  @NAPI()
  final int value;

  int _reads = 0;

  @NAPI()
  List<int>? get values => [++_reads];
}

@NAPI()
Point echoPoint(Point value) => value;

@NAPI()
Offset echoOffset(Offset value) => value;

final _shared = Point.parse(value: '3', label: 'shared');

@NAPI()
Point sharedPoint() => _shared;

class _LoopPoint extends Point {
  _LoopPoint() : super.parse(value: '1');

  @override
  Point get next => this;
}

@NAPI()
Point cyclicPoint() => _LoopPoint();

@NAPI()
Readout readout() => Readout(9);

@NAPI()
Point transformPoint(Point value, Point Function(Point) transform) =>
    transform(value);

@NAPI()
Future<List<({String key, Point point})>> pointEntries(
  Future<Map<String, Point>> values,
) async => [
  for (final entry in (await values).entries)
    (key: entry.key, point: entry.value),
];

@NAPI()
Stream<Point> pointStream(Point value) async* {
  yield value;
}
