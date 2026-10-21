import 'dart:async';
import 'dart:collection';

import '../api/cancellation.dart';
import 'resources.dart';
import 'retention.dart';

/// The outcome of one accepted host delivery. Payloads are never awaited.
enum StreamDeliveryKind { value, done, error }

/// Identifies the adapter's overflow separately from ordinary Dart source errors.
final class StreamBufferOverflow extends RangeError {
  StreamBufferOverflow(int capacity)
    : super('Stream buffer limit ($capacity) exceeded.');
}

/// A host delivery owns its snapshot until the Promise transport acknowledges it.
final class StreamDelivery<S extends Object> implements OperationLease {
  StreamDelivery._(
    this._owner,
    this.kind,
    this._value,
    this._error,
    this._stack,
  );

  NapiStream<dynamic, S>? _owner;
  final StreamDeliveryKind kind;
  S? _value;
  Object? _error;
  StackTrace? _stack;

  S? get value => _value;
  Object? get error => _error;
  StackTrace? get stack => _stack;
  @override
  bool get isReleased => _owner == null;

  @override
  void release() {
    final owner = _owner;
    if (owner == null) return;
    _owner = null;
    final value = _value;
    _value = null;
    _error = null;
    _stack = null;
    owner._acknowledge(value);
  }
}

/// One lazy subscription and the original call's roots, shared by both targets.
///
/// [snapshot] produces an independently owned, non-null host envelope. It must
/// finish all payload conversion at admission; delivery only builds the outer
/// iterator result. [releaseSnapshot] drops that envelope, never a business
/// resource. Generated transports call [finishCreation] after facade adoption
/// and release every [StreamDelivery] after host settlement, including errors.
final class NapiStream<T, S extends Object> {
  NapiStream(
    Stream<T> source, {
    required this._snapshot,
    this._releaseSnapshot,
    required List<Object?> roots,
    ResourceOperation? operation,
    List<AbortSignal> signals = const [],
    this.capacity = 64,
  }) : _source = source,
       retainedInputs = List<Object?>.of(roots),
       _operation = operation {
    if (capacity < 1) throw ArgumentError.value(capacity, 'capacity');
    // Observe only this private Dart completion, never a public JS Promise.
    _cancelled.future.then<void>(
      (_) => _didCancel(),
      onError: (Object error, StackTrace stack) => _didCancel(error, stack),
    );
    operation?.attachStream(this, _closeStream);
    if (signals.isNotEmpty && !_terminated) {
      try {
        _attachSignals(signals);
      } catch (_) {
        finishCreation(false);
        rethrow;
      }
    }
  }

  final int capacity;
  final S Function(T) _snapshot;
  final void Function(S)? _releaseSnapshot;

  /// The same list is exposed to traced host roots and cleared at final release.
  final List<Object?> retainedInputs;
  ResourceOperation? _operation;
  List<AbortSignal>? _signals;
  List<void Function()>? _abortListeners;
  Stream<T>? _source;
  StreamSubscription<T>? _subscription;
  final _items = ListQueue<_StreamItem<S>>();
  final _reads = ListQueue<Completer<StreamDelivery<S>>>();
  final _returns = ListQueue<Completer<StreamDelivery<S>>>();
  final _cancelled = Completer<void>();
  Object? _error;
  StackTrace? _stack;
  Object? _cancelError;
  StackTrace? _cancelStack;
  bool _creating = true;
  bool _started = false;
  bool _broadcast = false;
  bool _paused = false;
  bool _terminated = false;
  bool _sourceDone = false;
  bool _closing = false;
  bool _cancelStarted = false;
  bool _cancelSettled = false;
  bool _draining = false;
  bool _again = false;
  bool _released = false;
  int _busy = 0;
  int _deliveries = 0;

  static Future<void> _closeStream(Object value) =>
      (value as NapiStream<dynamic, Object>)._requestClose();

  void _attachSignals(List<AbortSignal> signals) {
    _signals = signals;
    final removers = _abortListeners = <void Function()>[];
    final target = WeakReference<NapiStream<dynamic, Object>>(this);
    for (final signal in signals) {
      if (_terminated) break;
      final remove = signal.onAbort(_abortListener(target, signal));
      if (_terminated) {
        remove();
      } else {
        removers.add(remove);
        if (signal.aborted) _abort(signal);
      }
    }
  }

  void _checkSignals() {
    final signals = _signals;
    if (signals == null) return;
    for (final signal in signals) {
      if (signal.aborted) {
        _abort(signal);
        return;
      }
    }
  }

  void _abort(AbortSignal signal) {
    if (_terminated) return;
    try {
      signal.throwIfAborted();
    } catch (error, stack) {
      _error = error;
      _stack = stack;
      _requestClose();
    }
  }

  void _detachSignals() {
    _signals = null;
    final removers = _abortListeners;
    if (removers == null) return;
    _abortListeners = null;
    for (final remove in removers) {
      remove();
    }
  }

  /// Ends the synchronous factory/adoption phase, including its failure path.
  void finishCreation(bool published) {
    if (!_creating) return;
    _creating = false;
    if (!published) _requestClose();
    _advance();
  }

  Future<StreamDelivery<S>> next() {
    // Host state can change before an owner-queued notification reaches Dart.
    _checkSignals();
    final read = Completer<StreamDelivery<S>>();
    _reads.add(read);
    _advance();
    return read.future;
  }

  Future<StreamDelivery<S>> return_() {
    final read = Completer<StreamDelivery<S>>();
    _returns.add(read);
    _requestClose();
    return read.future;
  }

  /// Aborts a failed outer-result/Promise delivery, already rejected by its host.
  void deliveryFailed(Object error, StackTrace stack) {
    _requestClose();
  }

  Future<void> _requestClose() {
    _closing = true;
    _terminated = true;
    _detachSignals();
    _discardItems();
    _advance();
    return _cancelled.future;
  }

  void _advance() {
    if (_draining) {
      _again = true;
      return;
    }
    _draining = true;
    try {
      do {
        _again = false;
        if (!_creating && !_started && !_terminated && _reads.isNotEmpty) {
          _checkSignals();
          if (!_terminated) _listen();
        }
        if (_terminated && !_sourceDone) _cancel();
        while (_reads.isNotEmpty) {
          if (_items.isNotEmpty) {
            final item = _items.first;
            if (!item.ready) break;
            _items.removeFirst();
            _deliver(
              _reads.removeFirst(),
              StreamDeliveryKind.value,
              item.value,
            );
          } else if (_terminated && (!_closing || _cancelSettled)) {
            if (_error != null) {
              if (_closing && _deliveries != 0) break;
              _deliver(
                _reads.removeFirst(),
                StreamDeliveryKind.error,
                null,
                _error,
                _stack,
              );
              _error = null;
              _stack = null;
            } else {
              _deliver(_reads.removeFirst(), StreamDeliveryKind.done);
            }
          } else {
            break;
          }
        }
        // Return waits for earlier accepted deliveries, then publishes its
        // waiting batch without waiting on that batch's own acknowledgements.
        if (_cancelSettled && _deliveries == 0) {
          while (_returns.isNotEmpty) {
            _deliver(
              _returns.removeFirst(),
              _cancelError == null
                  ? StreamDeliveryKind.done
                  : StreamDeliveryKind.error,
              null,
              _cancelError,
              _cancelStack,
            );
          }
        }
        _updatePause();
      } while (_again);
    } finally {
      _draining = false;
      _releaseIfFinished();
    }
  }

  void _listen() {
    _started = true;
    _busy++;
    try {
      final subscription = _inOperation(() {
        final source = _source!;
        _broadcast = source.isBroadcast;
        return source.listen(
          _onData,
          onError: _onError,
          onDone: _onDone,
          cancelOnError: false,
        );
      });
      if (!_sourceDone) _subscription = subscription;
      _source = null;
    } catch (error, stack) {
      _fail(error, stack);
    } finally {
      _busy--;
    }
  }

  void _onData(T value) {
    if (_terminated) return;
    if (_items.length >= capacity) {
      _fail(StreamBufferOverflow(capacity), StackTrace.current);
      _advance();
      return;
    }
    // Reserve event order before traversing business getters, which may reenter.
    final item = _StreamItem<S>();
    _items.add(item);
    _busy++;
    try {
      final snapshot = _inOperation(() => _snapshot(value));
      if (_closing) {
        _releaseSnapshot?.call(snapshot);
      } else {
        item.value = snapshot;
        item.ready = true;
      }
    } catch (error, stack) {
      _items.remove(item);
      _fail(error, stack);
    } finally {
      _busy--;
      _advance();
    }
  }

  void _onError(Object error, StackTrace stack) {
    _fail(error, stack);
    _advance();
  }

  void _fail(Object error, StackTrace stack) {
    if (_terminated) return;
    _terminated = true;
    _error = error;
    _stack = stack;
    _detachSignals();
    _again = true;
  }

  void _onDone() {
    if (_terminated) return;
    _terminated = true;
    _detachSignals();
    _sourceDone = true;
    _source = null;
    _subscription = null;
    _cancelStarted = true;
    _cancelled.complete();
    _advance();
  }

  void _updatePause() {
    final subscription = _subscription;
    if (subscription == null || _broadcast || _terminated) return;
    final pause = _reads.isEmpty;
    if (pause == _paused) return;
    _paused = pause;
    _busy++;
    try {
      if (pause) {
        _inOperation(subscription.pause);
      } else {
        _inOperation(subscription.resume);
      }
    } catch (error, stack) {
      _fail(error, stack);
    } finally {
      _busy--;
      if (_terminated) _cancel();
    }
  }

  void _cancel() {
    if (_cancelStarted || _creating || _busy != 0) return;
    _cancelStarted = true;
    final subscription = _subscription;
    _source = null;
    _subscription = null;
    try {
      if (subscription == null) {
        _cancelled.complete();
      } else {
        _cancelled.complete(_inOperation(subscription.cancel));
      }
    } catch (error, stack) {
      _cancelled.completeError(error, stack);
    }
  }

  void _didCancel([Object? error, StackTrace? stack]) {
    _cancelSettled = true;
    _cancelError = error;
    _cancelStack = stack;
    _advance();
  }

  R _inOperation<R>(R Function() body) {
    final operation = _operation;
    return operation == null ? body() : operation.run(body);
  }

  void _deliver(
    Completer<StreamDelivery<S>> read,
    StreamDeliveryKind kind, [
    S? value,
    Object? error,
    StackTrace? stack,
  ]) {
    // Pairing is the acceptance point. Return never retracts this delivery.
    _deliveries++;
    read.complete(StreamDelivery._(this, kind, value, error, stack));
  }

  void _discardItems() {
    final values = [
      for (final item in _items)
        if (item.ready) item.value!,
    ];
    _items.clear();
    for (final value in values) {
      _releaseSnapshot?.call(value);
    }
  }

  void _acknowledge(S? value) {
    try {
      if (value != null) _releaseSnapshot?.call(value);
    } finally {
      _deliveries--;
      _advance();
    }
  }

  void _releaseIfFinished() {
    if (_released ||
        !_terminated ||
        !_cancelSettled ||
        _creating ||
        _busy != 0 ||
        _items.isNotEmpty ||
        _reads.isNotEmpty ||
        _returns.isNotEmpty ||
        _deliveries != 0 ||
        (!_closing && _error != null)) {
      return;
    }
    _released = true;
    final operation = _operation;
    _operation = null;
    retainedInputs.clear();
    operation?.release();
  }
}

final class _StreamItem<S extends Object> {
  bool ready = false;
  S? value;
}

// A live token owns only this weak stream target, never the factory's context.
void Function() _abortListener(
  WeakReference<NapiStream<dynamic, Object>> target,
  AbortSignal signal,
) =>
    () => target.target?._abort(signal);
