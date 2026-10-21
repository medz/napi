import 'dart:async';

import 'package:napi/napi.dart';

int _entries = 0;
final _events = <String>[];
final _work = <int, Completer<int>>{};
final _cancels = <int, Completer<void>>{};
WeakReference<AbortSignal>? _weakSignal;
void Function()? _retainedRemoval;
void Function()? _conversionCallback;
List<int> _pressure = [];

@NAPI()
int entries() => _entries;
@NAPI()
List<String> events() => List.of(_events);
@NAPI()
bool check(AbortSignal signal) {
  _entries++;
  signal.throwIfAborted();
  return signal.aborted;
}

@NAPI()
bool peekAfter(AbortSignal signal, void Function() callback) {
  _entries++;
  callback();
  return signal.aborted;
}

@NAPI()
int checkAfter(AbortSignal signal, void Function() callback) {
  _entries++;
  callback();
  signal.throwIfAborted();
  return 1;
}

@NAPI()
int guarded(AbortSignal signal, GuardValue value) {
  _entries++;
  return value.value;
}

@NAPI()
int setConversion(void Function()? callback) {
  _conversionCallback = callback;
  return 1;
}

@NAPI(classPolicy: ClassPolicy.value)
class GuardValue {
  final int value;
  GuardValue(this.value) {
    _conversionCallback?.call();
  }
}

@NAPI()
Future<int> immediate(AbortSignal signal) {
  _entries++;
  return Future.value(42);
}

@NAPI()
bool optional([AbortSignal? signal]) => signal?.aborted ?? false;
@NAPI()
bool named({AbortSignal? signal, AbortSignal? other}) =>
    identical(signal, other);
@NAPI()
Future<T> resolved<T>(AbortSignal signal, T value) => Future.value(value);
@NAPI()
int completeWork(int id, [int value = 42]) {
  _events.add('stopped:$id');
  _work.remove(id)!.complete(value);
  return value;
}

Future<int> _run(AbortSignal signal, int id, bool ignore) async {
  _entries++;
  final done = Completer<int>();
  _work[id] = done;
  final remove = signal.onAbort(() => _events.add('request:$id'));
  try {
    final result = await done.future;
    if (!ignore) signal.throwIfAborted();
    return result;
  } finally {
    remove();
    _events.add('finished:$id');
  }
}

@NAPI()
Future<int> work(AbortSignal signal, int id, {bool ignore = false}) =>
    _run(signal, id, ignore);

@NAPI()
Future<int> timerWork(AbortSignal signal, int milliseconds) async {
  final done = Completer<int>();
  final timer = Timer(Duration(milliseconds: milliseconds), () {
    _events.add('timer-fired');
    done.complete(42);
  });
  final remove = signal.onAbort(() {
    timer.cancel();
    _events.add('timer-stopped');
    if (done.isCompleted) return;
    try {
      signal.throwIfAborted();
    } catch (error, stack) {
      done.completeError(error, stack);
    }
  });
  try {
    return await done.future;
  } finally {
    remove();
    timer.cancel();
  }
}

@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class WorkOwner {
  final int id;
  WorkOwner(this.id);
  Future<int> work(AbortSignal signal, int task) => _run(signal, task, false);
  void close() => _events.add('cleanup:$id');
}

@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class CleanupSignal {
  final int id;
  CleanupSignal(this.id);
  void close(AbortSignal signal) => _events.add('cleanup:$id');
}

@NAPI()
class SavedSignal {
  AbortSignal? _signal;
  void Function()? _remove;
  SavedSignal([AbortSignal? signal]) : _signal = signal;
  set signal(AbortSignal value) => _signal = value;
  bool get aborted => _signal!.aborted;
  bool same(AbortSignal? signal) => identical(_signal, signal);
  void check() => _signal!.throwIfAborted();
  void listen(void Function() callback) {
    _remove?.call();
    _remove = _signal!.onAbort(callback);
  }

  void remove() {
    _remove?.call();
    _remove = null;
  }

  void forget() {
    remove();
    _signal = null;
  }
}

@NAPI()
int remember(AbortSignal signal, void Function() callback, bool retainRemoval) {
  _weakSignal = WeakReference(signal);
  final remove = signal.onAbort(callback);
  if (retainRemoval) _retainedRemoval = remove;
  return 1;
}

@NAPI()
bool tokenAlive() => _weakSignal?.target != null;
@NAPI()
int removeRetained() {
  _retainedRemoval?.call();
  _retainedRemoval = null;
  return 1;
}

@NAPI()
int pressure() {
  _pressure = List.generate(250000, (i) => i);
  return _pressure.last;
}

@NAPI()
int cancelComplete(int id) {
  _cancels.remove(id)!.complete();
  return id;
}

@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class SignalFeed {
  final int id;
  final bool delayed;
  final bool failCancel;
  final bool failCleanup;
  late final StreamController<int> _source;
  int listens = 0;
  int cancels = 0;
  SignalFeed(
    this.id, {
    this.delayed = false,
    this.failCancel = false,
    this.failCleanup = false,
  }) {
    _source = StreamController<int>(
      sync: true,
      onListen: () => listens++,
      onCancel: () async {
        cancels++;
        _events.add('cancel:$id');
        if (delayed) {
          final gate = Completer<void>();
          _cancels[id] = gate;
          await gate.future;
        }
        if (failCancel) throw StateError('cancel-failure:$id');
      },
    );
  }
  Stream<int> watch(AbortSignal signal, {AbortSignal? other}) {
    _entries++;
    return _source.stream;
  }

  void emit(int value) => _source.add(value);
  void fail() => _source.addError(StateError('source-failure:$id'));
  void finish() => unawaited(_source.close());
  void close() {
    _events.add('cleanup:$id');
    if (failCleanup) throw StateError('cleanup-failure:$id');
  }
}

@NAPI()
Stream<int> once(AbortSignal signal) {
  _entries++;
  return Stream.value(7);
}
