import 'dart:async';

import 'package:napi/napi.dart';

int _calls = 0;
final _events = <String>[];
final _cancelGates = <int, Completer<void>>{};
final _sources = <int, StreamController<int>>{};
WeakReference<StreamBox>? _weakBox;
List<int> _pressure = [];

@NAPI()
int streamCalls() => _calls;
@NAPI()
List<String> streamEvents() => List.of(_events);
@NAPI()
int releaseCancel(int id) {
  _cancelGates.remove(id)!.complete();
  return id;
}

@NAPI()
int emitHeld(int id, int value) {
  _sources[id]!.add(value);
  return value;
}

@NAPI()
Stream<int> range([int count = 3]) {
  _calls++;
  if (count < 0) throw StateError('stream-factory-error');
  return Stream.fromIterable(List.generate(count, (index) => index));
}

@NAPI()
Stream<int> generated(int count) async* {
  for (var i = 0; i < count; i++) {
    await Future<void>.value();
    yield i;
  }
}

@NAPI()
Stream<void> voidItems() async* {
  yield null;
  yield null;
}

@NAPI()
Stream<T> echoItems<T>(T value) => Stream.value(value);
@NAPI()
Stream<String?> textItems(List<String?> values) => Stream.fromIterable(values);
@NAPI()
Stream<double> doubleItems(List<double> values) => Stream.fromIterable(values);
@NAPI(bigint: true)
Stream<int> wideItems(List<int> values) => Stream.fromIterable(values);
@NAPI()
Stream<BigInt> hugeItems(List<BigInt> values) => Stream.fromIterable(values);
@NAPI()
Stream<int> unsafeItems() => Stream.fromIterable([1, 9007199254740992, 3]);
@NAPI()
Stream<int> sourceError() async* {
  yield 7;
  throw StateError('stream-source-error');
}

@NAPI()
Stream<int> callbackError(void Function() callback) async* {
  yield 5;
  callback();
}

@NAPI()
class StreamBox {
  int value;
  StreamBox(this.value);
  Stream<int> get values => Stream.value(value);
  Stream<int> add([int amount = 1]) => Stream.value(value + amount);
  static Stream<String> label() => Stream.value('StreamBox');
}

@NAPI(classPolicy: ClassPolicy.value)
class StreamPoint {
  final int x;
  StreamPoint(this.x);
}

@NAPI()
Stream<StreamPoint> pointItems(StreamPoint point) => Stream.value(point);
@NAPI()
Stream<(StreamBox, {List<StreamBox?> peers})> rowItems(
  (StreamBox, {List<StreamBox?> peers}) row,
) => Stream.value(row);
@NAPI()
Stream<Map<String, StreamBox?>> mapItems(Map<String, StreamBox?> value) =>
    Stream.value(value);

/// Tests a normal single subscription, including pause and resume hooks.
@NAPI()
class IntFeed {
  late final StreamController<int> _controller;
  int listens = 0;
  int cancels = 0;
  int pauses = 0;
  int resumes = 0;
  IntFeed([bool broadcast = false]) {
    if (broadcast) {
      _controller = StreamController<int>.broadcast(
        sync: true,
        onListen: () => listens++,
        onCancel: () => cancels++,
      );
    } else {
      _controller = StreamController<int>(
        sync: true,
        onListen: () => listens++,
        onCancel: () => cancels++,
        onPause: () => pauses++,
        onResume: () => resumes++,
      );
    }
  }
  Stream<int> get values => _controller.stream;
  void emit(int value) => _controller.add(value);
  void finish() {
    unawaited(_controller.close());
  }

  void fail() => _controller.addError(StateError('feed-source-error'));
}

@NAPI()
class OpaqueFeed<T> {
  final _controller = StreamController<T>.broadcast(sync: true);
  Stream<T> get values => _controller.stream;
  void emit(T value) => _controller.add(value);
  void finish() {
    unawaited(_controller.close());
  }
}

@NAPI()
class SnapshotFeed {
  final _controller = StreamController<List<int>>.broadcast(sync: true);
  Stream<List<int>> get values => _controller.stream;
  void emit(int value) {
    final row = [value];
    _controller.add(row);
    row[0] = 99;
    row.add(100);
  }

  void unsafe() => _controller.add([9007199254740992]);
}

@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class StreamOwner {
  final int id;
  final bool failCleanup;
  StreamOwner(this.id, [this.failCleanup = false]);
  Stream<int> watch(
    int token, {
    bool delayedCancel = false,
    bool failCancel = false,
    StreamOwner? peer,
    List<StreamOwner>? peers,
    void Function()? duringFactory,
    void Function()? duringListen,
    void Function()? duringCancel,
  }) {
    _events.add('factory:$token');
    duringFactory?.call();
    final controller = StreamController<int>(
      sync: true,
      onListen: () {
        _events.add('listen:$token');
        duringListen?.call();
      },
      onCancel: () async {
        _events.add('cancel:$token');
        duringCancel?.call();
        if (delayedCancel) {
          final gate = Completer<void>();
          _cancelGates[token] = gate;
          await gate.future;
        }
        _sources.remove(token);
        _events.add('cancelled:$token');
        if (failCancel) throw StateError('cancel-error:$token');
      },
    );
    _sources[token] = controller;
    return controller.stream;
  }

  Stream<StreamOwner> self() => Stream.value(this);
  void close() {
    _events.add('cleanup:$id');
    if (failCleanup) throw StateError('cleanup-error:$id');
  }
}

@NAPI()
Stream<int> holdInputs<T>(int token, T payload, StreamBox box) {
  _weakBox = WeakReference(box);
  final controller = StreamController<int>(sync: true);
  _sources[token] = controller;
  return controller.stream;
}

@NAPI()
bool heldBoxAlive() => _weakBox?.target != null;
@NAPI()
int streamPressure(int seed) {
  _pressure = List.generate(100000, (index) => index ^ seed);
  return _pressure.last;
}

@NAPI()
abstract class StreamLeft {
  StreamLeft._();
  int get left;
}

@NAPI()
abstract class StreamRight {
  StreamRight._();
  int get right;
}

class _StreamBoth implements StreamLeft, StreamRight {
  @override
  int get left => 11;
  @override
  int get right => 13;
}

@NAPI()
Stream<StreamLeft> compositeItems() => Stream.value(_StreamBoth());
@NAPI()
Stream<StreamRight> rightItems(StreamRight value) => Stream.value(value);
