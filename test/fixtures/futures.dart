import 'dart:async';
import 'dart:collection';

import 'package:napi/napi.dart';

int _calls = 0;
int _points = 0;
Completer<int>? _gate;
Completer<int>? _receiverGate;
WeakReference<FutureBox>? _pendingBox;
WeakReference<FutureCounter>? _pendingReceiver;
FutureChild? _partial;
List<int> _pressure = [];

@NAPI()
int futureCalls() => _calls;
@NAPI()
int futurePointConstructions() => _points;

// Deliberately not async: calling the declaration and subscribing to its
// returned Future are separate operations, both with observable failures.
@NAPI()
Future<int> futureValue(int value) {
  _calls++;
  return Future.value(value);
}

@NAPI()
Future<int> futureDefault([int value = 7]) {
  _calls++;
  return Future.value(value);
}

@NAPI()
Future<void> futureVoid() async {
  await Future<void>.value();
  _calls++;
}

@NAPI()
Future<String?> futureNullable(String? value) => Future.value(value);
@NAPI()
Future<String> futureText(String value) async => value;
@NAPI()
Future<bool> futureBool(bool value) => Future.value(value);
@NAPI()
Future<double> futureDouble(double value) => Future.value(value);
@NAPI(bigint: true)
Future<int> futureWide(int value) => Future.value(value);
@NAPI()
Future<BigInt> futureBigInt(BigInt value) async => value;

@NAPI()
Future<List<int>> futureSnapshot(List<int> value, {int offset = 7}) {
  _calls++;
  return Future.delayed(
    const Duration(milliseconds: 20),
    () => [for (final item in value) item + offset],
  );
}

@NAPI()
Future<int> futureRequired({required int? value}) => Future.value(value ?? 9);
@NAPI()
Future<int> futureInputOrder(List<int> first, int requiredSecond) =>
    Future.value(first.length + requiredSecond);
@NAPI()
Future<int> futureReferenceOrder(List<int> first, FutureBox second) =>
    Future.value(first.length + second.value);
@NAPI()
Future<int> futureDelay(int value, int milliseconds) =>
    Future.delayed(Duration(milliseconds: milliseconds), () => value);
@NAPI()
Future<void> futureNever() => Completer<void>().future;

@NAPI()
Future<int> futureSyncError() => throw StateError('future-sync-error');
@NAPI()
Future<int> futureAsyncError() async {
  await Future<void>.value();
  throw StateError('future-async-error');
}

@NAPI()
Future<int> futureHostileError() => Future.error(_HostileError());
@NAPI()
Future<int> futureHostileStack() =>
    Future.error(StateError('future-hostile-stack'), _HostileStack());
@NAPI()
Future<int> futureUnsafeResult() => Future.value(9007199254740992);

class _HostileError {
  @override
  String toString() => throw StateError('future-error-formatter');
}

class _HostileStack implements StackTrace {
  @override
  String toString() => throw StateError('future-stack-formatter');
}

@NAPI()
class FutureCounter {
  int value;
  FutureCounter([this.value = 0]);
  Future<int> add([int amount = 1]) {
    value += amount;
    return Future.value(value);
  }

  Future<int> get current => Future.value(value);
  Future<int> later(int milliseconds) =>
      Future.delayed(Duration(milliseconds: milliseconds), () => value);
  Future<int> hold() {
    _pendingReceiver = WeakReference(this);
    _receiverGate = Completer<int>();
    return _receiverGate!.future;
  }

  Future<int> orphan() {
    _pendingReceiver = WeakReference(this);
    return Completer<int>().future;
  }

  static Future<String> label() => Future.value('FutureCounter');
}

@NAPI()
class FutureBox {
  int value;
  FutureBox(this.value);
}

@NAPI(name: 'Promise')
class DartPromise {
  int value;
  DartPromise(this.value);
}

@NAPI()
Future<DartPromise> futureNamedPromise(DartPromise value) =>
    Future.value(value);

@NAPI(classPolicy: ClassPolicy.value)
class FuturePoint {
  final int x;
  final int y;
  FuturePoint(this.x, {this.y = 7}) {
    _points++;
  }
}

@NAPI()
Future<FuturePoint> futurePoint(FuturePoint value) => Future.value(value);
@NAPI()
Future<FutureBox> futureReference(FutureBox value) => Future.value(value);
@NAPI()
Future<(FutureBox, {List<FutureBox?> peers})> futureRows(
  (FutureBox, {List<FutureBox?> peers}) value,
) => Future.value(value);
@NAPI()
Future<Map<String, FutureBox?>> futureMap(Map<String, FutureBox?> value) =>
    Future.value(value);
@NAPI()
Future<Dictionary<FutureBox?>> futureDictionary(Dictionary<FutureBox?> value) =>
    Future.value(value);
@NAPI()
Future<List<FutureBox?>?> futureNullableRows(List<FutureBox?>? value) =>
    Future.value(value);

@NAPI()
Future<int> futureHold(FutureBox value) {
  _gate = Completer<int>();
  _pendingBox = WeakReference(value);
  // The Future itself never captures value. Its lifetime is the adapter's job.
  return _gate!.future;
}

@NAPI()
Future<int> futureOrphan(FutureBox value) {
  _pendingBox = WeakReference(value);
  return Completer<int>().future;
}

@NAPI()
bool futureHeldAlive() => _pendingBox?.target != null;
@NAPI()
bool futureReceiverAlive() => _pendingReceiver?.target != null;
@NAPI()
int futureComplete() {
  _gate!.complete(81);
  _gate = null;
  _receiverGate!.complete(19);
  _receiverGate = null;
  return 0;
}

@NAPI()
int futurePressure(int seed) {
  _pressure = List<int>.generate(65536, (index) => index + seed);
  return _pressure[seed & 65535];
}

@NAPI()
class FutureBase {
  FutureBase();
}

@NAPI()
class FutureChild extends FutureBase {
  FutureChild();
}

@NAPI()
Future<(FutureBase, int)> futureFailedReference() =>
    Future.value((_partial = FutureChild(), 9007199254740992));
@NAPI()
Future<(FutureBase, int)> futureFailedExisting(FutureBase value) =>
    Future.value((value, 9007199254740992));
@NAPI()
Future<FutureChild> futurePartialChild() => Future.value(_partial!);

@NAPI()
Future<int> futureAdversarial(int mode) => _AdversarialFuture(mode);

@NAPI()
Future<List<int>> futureReentrantCompletion() => _ReentrantFuture();

@NAPI()
Future<int> futureReentrantError() => _ReentrantErrorFuture();

class _ReentrantErrorFuture implements Future<int> {
  @override
  Future<R> then<R>(FutureOr<R> Function(int) onValue, {Function? onError}) {
    Function.apply(onError!, [
      _ReentrantError(() => onValue(99)),
      StackTrace.current,
    ]);
    return Completer<R>().future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unused Future member');
}

class _ReentrantError {
  final void Function() reenter;
  _ReentrantError(this.reenter);
  @override
  String toString() {
    reenter();
    return 'future-first-reentrant-error';
  }
}

class _ReentrantFuture implements Future<List<int>> {
  @override
  Future<R> then<R>(
    FutureOr<R> Function(List<int>) onValue, {
    Function? onError,
  }) {
    onValue(_ReentrantList(() => onValue([99])));
    return Completer<R>().future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unused Future member');
}

class _ReentrantList extends ListBase<int> {
  final void Function() reenter;
  bool entered = false;
  _ReentrantList(this.reenter);
  @override
  int get length {
    if (!entered) {
      entered = true;
      reenter();
    }
    return 1;
  }

  @override
  set length(int value) => throw UnsupportedError('fixed length');
  @override
  int operator [](int index) => 17;
  @override
  void operator []=(int index, int value) => throw UnsupportedError('readonly');
}

// Custom Future implementations are allowed to throw from then registration.
// A broken implementation must still not settle the public Promise twice.
class _AdversarialFuture implements Future<int> {
  final int mode;
  _AdversarialFuture(this.mode);
  @override
  Future<R> then<R>(FutureOr<R> Function(int) onValue, {Function? onError}) {
    if (mode == 2) throw StateError('future-registration-error');
    if (mode == 1 || mode == 4) {
      Function.apply(onError!, [
        StateError('future-first-error'),
        StackTrace.current,
      ]);
    } else {
      onValue(17);
    }
    if (mode == 5) {
      Timer.run(() {
        onValue(99);
        Function.apply(onError!, [
          StateError('future-late-duplicate-error'),
          StackTrace.current,
        ]);
      });
      return Completer<R>().future;
    }
    if (mode == 3 || mode == 4) throw StateError('future-after-settlement');
    onValue(99);
    Function.apply(onError!, [
      StateError('future-duplicate-error'),
      StackTrace.current,
    ]);
    return Completer<R>().future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unused Future member');
}

void main() => throw StateError('Future business main must not run');
