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
  Set<_ResourceStreamNotice>? _streams;
  List<Future<void>?>? _cancellationErrors;
  int _pendingCancellations = 0;

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
  /// Attached streams cancel before cleanup. A cleanup failure takes priority;
  /// otherwise the first cancellation failure in attachment order is forwarded.
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
          final cancellation = _firstCancellationError;
          final settled = cancellation == null
              ? result
              : result.then<void>((_) => cancellation);
          completion.complete(settled.whenComplete(() => _owner = null));
        } else {
          _finish();
        }
      } catch (error, stack) {
        _finish(error, stack);
      }
    });
    final streams = _streams;
    if (streams == null) {
      if (_operations == 0) _runCleanup();
    } else {
      _cancelStreams(streams.toList(growable: false));
      _tryCleanup();
    }
    return completion.future;
  }

  void _release() {
    _operations--;
    _tryCleanup();
  }

  void _tryCleanup() {
    if (_operations == 0 && _pendingCancellations == 0 && _cleanup != null) {
      _runCleanup();
    }
  }

  Future<void>? get _firstCancellationError {
    final errors = _cancellationErrors;
    if (errors == null) return null;
    for (final error in errors) {
      if (error != null) return error;
    }
    return null;
  }

  void _cancelStreams(List<_ResourceStreamNotice> notices) {
    if (notices.isEmpty) return;
    final errors = _cancellationErrors ??= [];
    final first = errors.length;
    // Reserve the entire registration order before cancellation can reenter.
    errors.addAll(List<Future<void>?>.filled(notices.length, null));
    _pendingCancellations += notices.length;
    for (final (offset, notice) in notices.indexed) {
      final future = notice.request();
      future.then<void>(
        (_) {
          _pendingCancellations--;
          _tryCleanup();
        },
        onError: (Object error, StackTrace stack) {
          // Forward the failed Future without intercepting its error twice.
          errors[first + offset] = future;
          _pendingCancellations--;
          _tryCleanup();
        },
      );
    }
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
      _completion!.complete(_firstCancellationError);
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

/// The distinct resources accepted by one generated call.
///
/// Adapters retain during conversion, before business constructors or getters
/// can reenter. They release after the final use, even if later conversion
/// fails. Cleanup exempts its own control to avoid waiting on its own lease.
final class ResourceOperation implements OperationLease {
  ResourceOperation({ResourceControl? exempt})
    : _group = _ResourceOperationGroup(exempt);

  ResourceOperation._(this._group) {
    _group.scopes++;
  }

  static final _zoneKey = Object();
  static ResourceOperation? get current =>
      Zone.current[_zoneKey] as ResourceOperation?;

  final _ResourceOperationGroup _group;
  bool _released = false;
  _ResourceStreamNotice? _stream;

  bool get isEmpty => _released || _group.leases.isEmpty;
  @override
  bool get isReleased => _released;

  /// Keeps an accepted asynchronous invocation alive independently of its caller.
  /// Releasing either scope invalidates it without ending the other scope.
  ResourceOperation fork() {
    if (_released) throw StateError('Resource operation is released.');
    return ResourceOperation._(_group);
  }

  /// Runs a call and its asynchronous continuations in this operation's scope.
  R run<R>(R Function() body) {
    if (_released) throw StateError('Resource operation is released.');
    if (identical(current, this)) return body();
    return runZoned(body, zoneValues: {_zoneKey: this});
  }

  void retain(ResourceControl? control) {
    if (_released) throw StateError('Resource operation is released.');
    if (control == null ||
        identical(control, _group.exempt) ||
        _group.leases.containsKey(control)) {
      return;
    }
    _group.leases[control] = control.retainOperation();
    final notices = _group.streams?.toList(growable: false);
    if (notices == null) return;
    for (final notice in notices) {
      if (!notice.operation.isReleased) notice.attach(control);
    }
    if (!_released && control.state != ResourceState.open) {
      control._cancelStreams(notices);
    }
  }

  /// Transfers close notification to one stream without strongly rooting it.
  ///
  /// [cancel] must be an unbound function: the notice keeps only a weak target,
  /// but retains this operation so an abandoned target cannot strand leases.
  void attachStream(Object target, Future<void> Function(Object) cancel) {
    if (_released || _stream != null) {
      throw StateError('Resource operation cannot attach another stream.');
    }
    final notice = _ResourceStreamNotice(this, target, cancel);
    _stream = notice;
    (_group.streams ??= []).add(notice);
    for (final control in _group.leases.keys.toList(growable: false)) {
      notice.attach(control);
      if (_released) return;
    }
    // All links exist before cancellation can synchronously reenter cleanup.
    for (final control in notice.controls.toList(growable: false)) {
      if (_released) break;
      if (control.state != ResourceState.open) control._cancelStreams([notice]);
    }
  }

  @override
  void release() {
    if (_released) return;
    _released = true;
    final notice = _stream;
    if (notice != null) {
      notice.detach();
      final streams = _group.streams!;
      streams.remove(notice);
      if (streams.isEmpty) _group.streams = null;
      _stream = null;
    }
    if (--_group.scopes != 0) return;
    final leases = _group.leases.values.toList(growable: false);
    _group.leases.clear();
    _group.exempt = null;
    // Cleanup may reenter disposal or other operations. This group is already
    // detached, so reentrant release cannot release any accepted use twice.
    for (final lease in leases.reversed) {
      lease.release();
    }
  }
}

final class _ResourceOperationGroup {
  _ResourceOperationGroup(this.exempt);

  ResourceControl? exempt;
  final leases = Map<ResourceControl, OperationLease>.identity();
  List<_ResourceStreamNotice>? streams;
  int scopes = 1;
}

final class _ResourceStreamNotice {
  _ResourceStreamNotice(this.operation, Object target, this.cancel)
    : target = WeakReference(target);

  final ResourceOperation operation;
  final WeakReference<Object> target;
  final Future<void> Function(Object) cancel;
  final List<ResourceControl> controls = [];
  Future<void>? _future;

  void attach(ResourceControl control) {
    controls.add(control);
    final streams = control._streams ??= {};
    streams.add(this);
    for (final previous in streams.toList(growable: false)) {
      if (!identical(previous, this) && previous.target.target == null) {
        previous.operation.release();
      }
    }
  }

  Future<void> request() {
    final existing = _future;
    if (existing != null) return existing;
    final completion = Completer<void>();
    _future = completion.future;
    final value = target.target;
    if (value == null) {
      operation.release();
      completion.complete();
    } else {
      completion.complete(Future<void>.sync(() => cancel(value)));
    }
    return completion.future;
  }

  void detach() {
    for (final control in controls) {
      control._streams?.remove(this);
    }
    controls.clear();
  }
}
