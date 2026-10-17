import 'dart:async';

import 'retention.dart';

/// The lifecycle shared by all bindings of an explicit resource.
enum ResourceState { open, closing, closed }

/// Coordinates explicit cleanup with accepted uses of one Dart object.
///
/// [forObject] returns the same control for the same object, including after its
/// JavaScript wrapper has been collected and recreated. The association is weak;
/// it does not keep an otherwise unreachable object alive or run cleanup for it.
/// Bindings must validate compatible cleanup policies before sharing a control.
final class ResourceControl implements OperationOwner {
  factory ResourceControl.forObject(Object owner) =>
      _controls[owner] ??= ResourceControl._(owner);

  ResourceControl._(this._owner);

  static final _controls = Expando<ResourceControl>('napi resource control');

  Object? _owner;
  int _operations = 0;
  Completer<void>? _completion;
  void Function()? _cleanup;

  ResourceState get state => _completion == null
      ? ResourceState.open
      : _owner == null
      ? ResourceState.closed
      : ResourceState.closing;

  /// Retains the resource until the returned lease is released.
  ///
  /// Adapters must release in `finally` after their operation's complete use of
  /// the resource, including result conversion or asynchronous settlement.
  @override
  OperationLease retainOperation() {
    if (_completion != null) {
      throw StateError('Resource is ${state.name}.');
    }
    _operations++;
    return _ResourceLease(this);
  }

  /// Rejects new operations and runs [cleanup] once accepted leases are released.
  ///
  /// The first call supplies the cleanup closure and its arguments. Later calls
  /// return the identical future and ignore their closure. Cleanup runs in the
  /// first call's zone. Future errors keep their error and stack; synchronous
  /// exceptions follow that zone's error interception. Success and failure close
  /// the resource permanently. Releasing a lease does not throw cleanup errors.
  ///
  /// Cleanup may reenter [dispose], but must not await its own disposal. Returning
  /// that future directly is rejected; an indirect circular wait cannot be
  /// detected. As with other Dart futures, errors follow the creation error zone.
  Future<void> dispose(FutureOr<void> Function() cleanup) {
    final existing = _completion;
    if (existing != null) return existing.future;

    final completion = Completer<void>();
    final zone = Zone.current;
    _completion = completion;
    _cleanup = () => zone.run(() {
      try {
        final result = cleanup();
        if (identical(result, completion.future)) {
          throw StateError('Resource cleanup cannot await its own disposal.');
        }
        if (result is Future<void>) {
          // Forward an existing asynchronous error without invoking the
          // disposal zone's errorCallback a second time.
          completion.complete(result.whenComplete(() => _owner = null));
        } else {
          _finish();
        }
      } catch (error, stack) {
        _finish(error, stack);
      }
    });
    if (_operations == 0) _runCleanup();
    return completion.future;
  }

  void _release() {
    _operations--;
    if (_operations == 0 && _cleanup != null) _runCleanup();
  }

  void _runCleanup() {
    final cleanup = _cleanup!;
    _cleanup = null;
    try {
      cleanup();
    } catch (error, stack) {
      // Also handle an exception from a custom zone's callback wrapper.
      _finish(error, stack);
    }
  }

  void _finish([Object? error, StackTrace? stack]) {
    if (_completion!.isCompleted) return;
    _owner = null;
    if (error == null) {
      _completion!.complete();
    } else {
      _completion!.completeError(error, stack);
    }
  }
}

final class _ResourceLease implements OperationLease {
  _ResourceLease(this._control);

  ResourceControl? _control;

  @override
  bool get isReleased => _control == null;

  @override
  void release() {
    final control = _control;
    if (control == null) return;
    _control = null;
    control._release();
  }
}
