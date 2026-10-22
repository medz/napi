import 'dart:async';

import 'resources.dart';

/// A yielded null is distinct from the end of an asynchronous iterator.
final class CallbackStreamItem<T> {
  const CallbackStreamItem.done() : done = true, value = null;
  const CallbackStreamItem.value(this.value) : done = false;

  final bool done;
  final T? value;
}

/// Pulls one host iterator at a time for a single Dart subscription.
final class NapiCallbackStream<T> {
  NapiCallbackStream({
    required this._next,
    required this._close,
    ResourceOperation? operation,
  }) : _operation = operation {
    _controller = StreamController<T>(
      sync: true,
      onListen: _pull,
      onResume: _pull,
      onCancel: _cancelSubscription,
    );
    operation?.attachStream(this, _cancelStream);
    if (operation != null) _finalizer.attach(this, operation, detach: this);
  }

  static final _finalizer = Finalizer<ResourceOperation>(
    (value) => value.release(),
  );
  static Future<void> _cancelStream(Object stream) =>
      (stream as NapiCallbackStream<dynamic>).cancel();

  late final StreamController<T> _controller;
  Future<CallbackStreamItem<T>> Function()? _next;
  Future<void> Function()? _close;
  ResourceOperation? _operation;
  Future<void>? _cancelling;
  bool _pulling = false;
  bool _cancelled = false;
  bool _ended = false;
  bool _failed = false;

  Stream<T> get stream => _controller.stream;

  Future<void> _pull() async {
    if (_pulling || _cancelled || _ended) return;
    _pulling = true;
    try {
      while (!_cancelled && !_ended && !_controller.isPaused) {
        final item = await _next!();
        if (_cancelled) break;
        if (item.done) {
          _finish();
        } else {
          _controller.add(item.value as T);
        }
      }
    } catch (error, stack) {
      if (!_cancelled) {
        _failed = true;
        _controller.addError(error, stack);
        try {
          await cancel();
        } catch (_) {
          // Preserve the iteration/conversion failure already delivered above.
        }
      }
    } finally {
      _pulling = false;
    }
  }

  Future<void> _cancelSubscription() {
    final result = cancel();
    if (!_failed) return result;
    // Dart's cancelOnError waits for onCancel before delivering the original
    // error. A second failure here would also escape that automatic wait.
    return result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
  }

  Future<void> cancel() {
    final existing = _cancelling;
    if (existing != null) return existing;
    if (_ended) return Future<void>.value();
    _cancelled = true;
    final completion = Completer<void>();
    _cancelling = completion.future;
    completion.complete(Future<void>.sync(_close!).whenComplete(_finish));
    return completion.future;
  }

  void _finish() {
    if (_ended) return;
    _ended = true;
    _next = null;
    _close = null;
    _finalizer.detach(this);
    final operation = _operation;
    _operation = null;
    operation?.release();
    // Closing a paused subscription can wait for its listener; resource release
    // depends on the host return operation, not on delivery of Dart's done event.
    _controller.close();
  }
}
