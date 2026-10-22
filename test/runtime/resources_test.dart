import 'dart:async';

import 'package:napi/runtime.dart';
import 'package:test/test.dart';

void main() {
  test('one control follows raw object identity, not equality or wrappers', () {
    final raw = _EqualOwner();
    final first = _Wrapper(raw);
    final alias = _Wrapper(raw);
    expect(first.control, same(alias.control));
    expect(first.control.state, ResourceState.open);
    expect(
      ResourceControl.forObject(_EqualOwner()),
      isNot(same(first.control)),
    );
  });

  test(
    'synchronous cleanup closes once and repeated disposal is identical',
    () async {
      final raw = Object();
      final control = ResourceControl.forObject(raw);
      var calls = 0;
      final disposed = control.dispose(() {
        calls++;
        expect(control.state, ResourceState.closing);
      });
      expect(control.state, ResourceState.closed);
      expect(control.dispose(() => fail('second cleanup')), same(disposed));
      await disposed;
      expect(ResourceControl.forObject(raw), same(control));
      expect(ResourceControl.forObject(raw).state, ResourceState.closed);
      expect(control.dispose(() => fail('late cleanup')), same(disposed));
      expect(calls, 1);
      expect(control.retainOperation, throwsStateError);
    },
  );

  test('all accepted leases finish before cleanup starts', () async {
    final control = ResourceControl.forObject(Object());
    final first = control.retainOperation();
    final second = control.retainOperation();
    var calls = 0;
    final disposed = control.dispose(() => calls++);
    expect(control.state, ResourceState.closing);
    expect(control.retainOperation, throwsStateError);
    expect(calls, 0);
    first.release();
    first.release();
    expect(first.isReleased, isTrue);
    expect(second.isReleased, isFalse);
    expect(calls, 0);
    expect(control.dispose(() => fail('second cleanup')), same(disposed));
    second.release();
    expect(second.isReleased, isTrue);
    expect(calls, 1);
    expect(control.state, ResourceState.closed);
    second.release();
    await disposed;
    expect(calls, 1);
  });

  test('releasing a lease while open does not close ordinary work', () async {
    final control = ResourceControl.forObject(Object());
    control.retainOperation().release();
    expect(control.state, ResourceState.open);
    final next = control.retainOperation();
    expect(next.isReleased, isFalse);
    next.release();
    await control.dispose(() {});
  });

  test('async cleanup stays closing until it completes', () async {
    final raw = Object();
    final control = ResourceControl.forObject(raw);
    final pending = Completer<void>();
    final disposed = control.dispose(() => pending.future);
    var settled = false;
    unawaited(disposed.then((_) => settled = true));
    expect(control.state, ResourceState.closing);
    expect(ResourceControl.forObject(raw), same(control));
    expect(ResourceControl.forObject(raw).retainOperation, throwsStateError);
    expect(control.dispose(() => fail('second cleanup')), same(disposed));
    await Future<void>.value();
    expect(settled, isFalse);
    pending.complete();
    await disposed;
    expect(settled, isTrue);
    expect(control.state, ResourceState.closed);
  });

  test(
    'first cleanup closure preserves its arguments until leases drain',
    () async {
      final raw = _Resource();
      final first = _Wrapper(raw);
      final lease = first.control.retainOperation();
      final disposed = first.control.dispose(
        () => raw.close('first', count: 7),
      );
      final readopted = _Wrapper(raw);
      expect(readopted.control, same(first.control));
      expect(readopted.control.state, ResourceState.closing);
      expect(
        readopted.control.dispose(() => raw.close('ignored', count: 99)),
        same(disposed),
      );
      expect(raw.closed, isNull);
      lease.release();
      await disposed;
      expect(raw.closed, ('first', 7));
      expect(_Wrapper(raw).control.state, ResourceState.closed);
    },
  );

  test(
    'synchronous cleanup failure is terminal and release does not throw',
    () async {
      final raw = Object();
      final control = ResourceControl.forObject(raw);
      final lease = control.retainOperation();
      final error = StateError('cleanup failed');
      final stack = StackTrace.fromString('original cleanup stack');
      var calls = 0;
      final disposed = control.dispose(() {
        calls++;
        Error.throwWithStackTrace(error, stack);
      });
      final observed = disposed.then<Object?>(
        (_) => fail('must fail'),
        onError: (Object actual, StackTrace actualStack) {
          expect(actual, same(error));
          expect(actualStack.toString(), stack.toString());
          expect(control.state, ResourceState.closed);
          return actual;
        },
      );
      expect(lease.release, returnsNormally);
      expect(lease.isReleased, isTrue);
      expect(await observed, same(error));
      expect(control.dispose(() => fail('retry cleanup')), same(disposed));
      await expectLater(disposed, throwsA(same(error)));
      expect(ResourceControl.forObject(raw).state, ResourceState.closed);
      expect(control.retainOperation, throwsStateError);
      expect(calls, 1);
    },
  );

  test(
    'asynchronous cleanup failure keeps its error and stack without retry',
    () async {
      final control = ResourceControl.forObject(Object());
      final pending = Completer<void>();
      final error = ArgumentError('async cleanup failed');
      final stack = StackTrace.fromString('original async stack');
      final disposed = control.dispose(() => pending.future);
      final observed = disposed.then<void>(
        (_) => fail('must fail'),
        onError: (Object actual, StackTrace actualStack) {
          expect(actual, same(error));
          expect(actualStack.toString(), stack.toString());
        },
      );
      pending.completeError(error, stack);
      await observed;
      expect(control.state, ResourceState.closed);
      expect(control.dispose(() => fail('retry cleanup')), same(disposed));
      await expectLater(disposed, throwsA(same(error)));
    },
  );

  for (final asynchronous in [false, true]) {
    test(
      '${asynchronous ? "async" : "sync"} cleanup errors are zone-intercepted once',
      () async {
        var interceptions = 0;
        final rewritten = StateError('rewritten once');
        final rewrittenStack = StackTrace.fromString('rewritten stack');
        await runZoned(
          () async {
            final control = ResourceControl.forObject(Object());
            final pending = Completer<void>();
            final original = StateError('original failure');
            final originalStack = StackTrace.fromString('original stack');
            final disposed = control.dispose(() {
              if (asynchronous) return pending.future;
              Error.throwWithStackTrace(original, originalStack);
            });
            if (asynchronous) pending.completeError(original, originalStack);
            for (var attempt = 0; attempt < 2; attempt++) {
              try {
                await disposed;
                fail('must fail');
              } catch (error, stack) {
                expect(error, same(rewritten));
                expect(stack.toString(), rewrittenStack.toString());
                expect(control.state, ResourceState.closed);
                expect(
                  control.dispose(() => fail('retry cleanup')),
                  same(disposed),
                );
              }
            }
          },
          zoneSpecification: ZoneSpecification(
            errorCallback: (self, parent, zone, error, stack) {
              interceptions++;
              return interceptions == 1
                  ? AsyncError(rewritten, rewrittenStack)
                  : AsyncError(StateError('rewritten again'), StackTrace.empty);
            },
          ),
        );
        expect(interceptions, 1);
      },
    );
  }

  test('cleanup Future listener registration failure closes once', () async {
    final control = ResourceControl.forObject(Object());
    final pending = Completer<void>();
    final error = StateError('registration failed');
    var failRegistration = false;
    final zone = Zone.current.fork(
      specification: ZoneSpecification(
        registerCallback: <R>(self, parent, zone, R Function() callback) {
          if (failRegistration) {
            failRegistration = false;
            throw error;
          }
          return parent.registerCallback(zone, callback);
        },
      ),
    );
    final disposed = zone.run(
      () => control.dispose(() {
        failRegistration = true;
        return pending.future;
      }),
    );
    expect(control.state, ResourceState.closed);
    await expectLater(disposed, throwsA(same(error)));
    expect(control.dispose(() => fail('retry cleanup')), same(disposed));
    pending.complete();
  });

  test(
    'a zone wrapper cannot settle an accepted async cleanup twice',
    () async {
      final control = ResourceControl.forObject(Object());
      final lease = control.retainOperation();
      final pending = Completer<void>();
      var throwAfterCleanup = false;
      final zone = Zone.current.fork(
        specification: ZoneSpecification(
          run: <R>(self, parent, zone, R Function() body) {
            final result = parent.run(zone, body);
            if (throwAfterCleanup) {
              throwAfterCleanup = false;
              throw StateError('zone wrapper after cleanup');
            }
            return result;
          },
        ),
      );
      final disposed = zone.run(() => control.dispose(() => pending.future));
      throwAfterCleanup = true;
      expect(lease.release, returnsNormally);
      expect(control.state, ResourceState.closing);
      pending.complete();
      await disposed;
      expect(control.state, ResourceState.closed);
    },
  );

  test('cleanup can reenter dispose but cannot acquire work', () async {
    final control = ResourceControl.forObject(Object());
    final lease = control.retainOperation();
    late Future<void> reentrant;
    final disposed = control.dispose(() {
      expect(lease.isReleased, isTrue);
      lease.release();
      expect(control.retainOperation, throwsStateError);
      reentrant = control.dispose(() => fail('reentrant cleanup'));
      expect(control.state, ResourceState.closing);
    });
    lease.release();
    expect(reentrant, same(disposed));
    await disposed;
  });

  test(
    'returning the disposal future fails instead of waiting on itself',
    () async {
      final control = ResourceControl.forObject(Object());
      final disposed = control.dispose(
        () => control.dispose(() => fail('reentrant cleanup')),
      );
      expect(control.state, ResourceState.closed);
      await expectLater(disposed, throwsStateError);
      expect(control.dispose(() => fail('retry cleanup')), same(disposed));
    },
  );

  test('failed synchronous work releases its lease before cleanup', () async {
    final control = ResourceControl.forObject(Object());
    final error = StateError('operation failed');
    late Future<void> disposed;
    var calls = 0;
    expect(() {
      final lease = control.retainOperation();
      try {
        disposed = control.dispose(() => calls++);
        throw error;
      } finally {
        lease.release();
      }
    }, throwsA(same(error)));
    await disposed;
    expect(calls, 1);
  });

  test(
    'accepted async work holds a lease through failure and result cleanup',
    () async {
      final control = ResourceControl.forObject(Object());
      final pending = Completer<void>();
      final events = <String>[];
      final error = StateError('operation failed');
      final lease = control.retainOperation();
      final operation = () async {
        try {
          await pending.future;
        } finally {
          events.add('operation finished');
          lease.release();
        }
      }();
      final operationError = expectLater(operation, throwsA(same(error)));
      final disposed = control.dispose(() => events.add('cleanup'));
      expect(events, isEmpty);
      expect(control.state, ResourceState.closing);
      pending.completeError(error);
      await operationError;
      await disposed;
      expect(events, ['operation finished', 'cleanup']);
      expect(lease.isReleased, isTrue);
    },
  );

  test('closing is published before the cleanup zone can reenter', () async {
    final control = ResourceControl.forObject(Object());
    final lease = control.retainOperation();
    var checkCleanupEntry = false;
    var calls = 0;
    Future<void>? reentrant;
    final zone = Zone.current.fork(
      specification: ZoneSpecification(
        run: <R>(self, parent, zone, R Function() body) {
          if (checkCleanupEntry) {
            checkCleanupEntry = false;
            expect(control.state, ResourceState.closing);
            expect(control.retainOperation, throwsStateError);
            reentrant = control.dispose(() => fail('zone reentrant cleanup'));
          }
          return parent.run(zone, body);
        },
      ),
    );
    final disposed = zone.run(() => control.dispose(() => calls++));
    checkCleanupEntry = true;
    lease.release();
    expect(reentrant, same(disposed));
    await disposed;
    expect(calls, 1);
    expect(control.state, ResourceState.closed);
  });

  test(
    'a cleanup zone invocation failure closes without escaping release',
    () async {
      final control = ResourceControl.forObject(Object());
      final lease = control.retainOperation();
      final error = StateError('zone invocation failed');
      var failCleanupEntry = false;
      final zone = Zone.current.fork(
        specification: ZoneSpecification(
          run: <R>(self, parent, zone, R Function() body) {
            if (failCleanupEntry) {
              failCleanupEntry = false;
              throw error;
            }
            return parent.run(zone, body);
          },
        ),
      );
      final disposed = zone.run(
        () => control.dispose(() => fail('cleanup must not run')),
      );
      final observed = expectLater(disposed, throwsA(same(error)));
      failCleanupEntry = true;
      expect(lease.release, returnsNormally);
      await observed;
      expect(control.state, ResourceState.closed);
      expect(control.dispose(() => fail('retry cleanup')), same(disposed));
    },
  );

  test('cleanup and error observation use the first dispose zone', () async {
    final control = ResourceControl.forObject(Object());
    final lease = control.retainOperation();
    final error = StateError('zoned cleanup failed');
    final key = Object();
    final observed = Completer<void>();
    final uncaught = <Object>[];
    late Future<void> disposed;
    runZonedGuarded(
      () {
        disposed = control.dispose(() async {
          expect(Zone.current[key], 'dispose');
          await Future<void>.value();
          expect(Zone.current[key], 'dispose');
          throw error;
        });
        unawaited(
          disposed.then<void>(
            (_) => fail('must fail'),
            onError: (Object actual, StackTrace stack) {
              expect(Zone.current[key], 'dispose');
              expect(actual, same(error));
              observed.complete();
            },
          ),
        );
      },
      (error, stack) => uncaught.add(error),
      zoneValues: {key: 'dispose'},
    );
    runZonedGuarded(
      () {
        expect(control.dispose(() => fail('second cleanup')), same(disposed));
        expect(lease.release, returnsNormally);
      },
      (error, stack) => uncaught.add(error),
      zoneValues: {key: 'release'},
    );
    await observed.future;
    expect(control.state, ResourceState.closed);
    expect(uncaught, isEmpty);
  });

  test(
    'operation scope follows async work and restores nested calls',
    () async {
      final operation = ResourceOperation();
      final nested = ResourceOperation();
      final control = ResourceControl.forObject(Object());
      final errorZone = Zone.current.errorZone;
      final parent = ResourceOperation.current;
      final pending = operation.run(() async {
        expect(ResourceOperation.current, same(operation));
        expect(Zone.current.errorZone, same(errorZone));
        final zone = Zone.current;
        operation.run(() => expect(Zone.current, same(zone)));
        nested.run(() => expect(ResourceOperation.current, same(nested)));
        expect(ResourceOperation.current, same(operation));
        await Future<void>.delayed(Duration.zero);
        expect(ResourceOperation.current, same(operation));
        expect(Zone.current.errorZone, same(errorZone));
        ResourceOperation.current!.retain(control);
      });
      expect(ResourceOperation.current, same(parent));
      await pending;
      var cleaned = false;
      final disposed = control.dispose(() => cleaned = true);
      expect(cleaned, isFalse);
      operation.release();
      nested.release();
      await disposed;
      expect(cleaned, isTrue);
      expect(ResourceOperation.current, same(parent));
    },
  );

  test('detached async work cannot retain after its operation ends', () async {
    final operation = ResourceOperation();
    final control = ResourceControl.forObject(Object());
    final gate = Completer<void>();
    final pending = operation.run(() async {
      await gate.future;
      expect(ResourceOperation.current, same(operation));
      expect(
        () => ResourceOperation.current!.retain(control),
        throwsStateError,
      );
    });
    operation.release();
    expect(() => operation.run(() {}), throwsStateError);
    gate.complete();
    await pending;
    await control.dispose(() {});
    expect(control.state, ResourceState.closed);
  });

  test(
    'accepted callback scopes outlive their caller without reopening it',
    () async {
      final operation = ResourceOperation();
      final first = ResourceControl.forObject(Object());
      final second = ResourceControl.forObject(Object());
      operation.retain(first);
      final callback = operation.fork();
      callback.retain(second);
      final cleaned = <String>[];
      final firstDone = first.dispose(() => cleaned.add('first'));
      final secondDone = second.dispose(() => cleaned.add('second'));
      // Both scopes share prior admissions, including aliases now closing.
      operation.retain(second);
      operation.release();
      expect(cleaned, isEmpty);
      expect(() => operation.retain(first), throwsStateError);
      expect(() => operation.fork(), throwsStateError);
      expect(() => operation.run(() {}), throwsStateError);
      callback.run(() {
        expect(ResourceOperation.current, same(callback));
        callback.retain(first);
        callback.retain(second);
      });
      final nested = callback.fork();
      callback.release();
      expect(cleaned, isEmpty);
      nested.release();
      nested.release();
      await Future.wait([firstDone, secondDone]);
      expect(cleaned, ['second', 'first']);
    },
  );

  test('stream cancellation waits for accepted callback scopes', () async {
    final operation = ResourceOperation();
    final callback = operation.fork();
    final control = ResourceControl.forObject(Object());
    var cancelled = false;
    var cleaned = false;
    final target = Object();
    operation.attachStream(target, (_) async {
      cancelled = true;
      operation.release();
    });
    callback.retain(control);
    final done = control.dispose(() => cleaned = true);
    expect(cancelled, isTrue);
    expect(operation.isReleased, isTrue);
    expect(cleaned, isFalse);
    callback.retain(control);
    callback.release();
    await done;
    expect(cleaned, isTrue);
  });

  test(
    'forked streams cancel independently before shared resource cleanup',
    () async {
      final control = ResourceControl.forObject(Object());
      final first = ResourceOperation()..retain(control);
      final second = first.fork();
      final target1 = Object(), target2 = Object();
      final gate = Completer<void>();
      final events = <String>[];
      first.attachStream(target1, (_) async {
        events.add('first');
        first.release();
      });
      second.attachStream(target2, (_) async {
        events.add('second');
        await gate.future;
        second.release();
      });
      final closing = control.dispose(() => events.add('cleanup'));
      await Future<void>.value();
      expect(events, ['first', 'second']);
      gate.complete();
      await closing;
      expect(events, ['first', 'second', 'cleanup']);
    },
  );

  test(
    'stream cancellation registers resources acquired after attachment',
    () async {
      final first = ResourceControl.forObject(Object());
      final second = ResourceControl.forObject(Object());
      final operation = ResourceOperation();
      final target = Object();
      final gate = Completer<void>();
      final cleaned = <String>[];
      var cancels = 0;
      late Future<void> secondDone;
      operation.attachStream(target, (_) {
        cancels++;
        secondDone = second.dispose(() => cleaned.add('second'));
        operation.release();
        return gate.future;
      });
      expect(
        () => operation.attachStream(target, (_) async {}),
        throwsStateError,
      );
      operation.retain(first);
      operation.retain(second);
      final firstDone = first.dispose(() => cleaned.add('first'));
      expect(cancels, 1, reason: 'reentrant disposal must share cancellation');
      expect(cleaned, isEmpty);
      expect(operation.isReleased, isTrue);
      gate.complete();
      await Future.wait([firstDone, secondDone]);
      expect(cleaned.toSet(), {'first', 'second'});
    },
  );

  test('one operation deduplicates resource aliases until its final release', () async {
    final first = ResourceControl.forObject(Object());
    final second = ResourceControl.forObject(Object());
    final operation = ResourceOperation();
    operation.retain(first);
    operation.retain(first);
    operation.retain(second);
    final cleaned = <String>[];
    final a = first.dispose(() => cleaned.add('first'));
    final b = second.dispose(() => cleaned.add('second'));
    // An alias already accepted by this operation remains usable while closing.
    operation.retain(first);
    expect(operation.isEmpty, isFalse);
    expect(cleaned, isEmpty);
    operation.release();
    operation.release();
    await Future.wait([a, b]);
    expect(cleaned, ['second', 'first']);
    expect(operation.isEmpty, isTrue);
    expect(operation.isReleased, isTrue);
  });

  test(
    'later rejected acquisition leaves earlier leases for rollback',
    () async {
      final open = ResourceControl.forObject(Object());
      final closed = ResourceControl.forObject(Object());
      await closed.dispose(() {});
      final operation = ResourceOperation();
      operation.retain(open);
      var cleaned = false;
      final done = open.dispose(() => cleaned = true);
      try {
        expect(() => operation.retain(closed), throwsStateError);
        expect(cleaned, isFalse);
      } finally {
        operation.release();
      }
      await done;
      expect(cleaned, isTrue);
    },
  );

  test(
    'cleanup exempts only its own control and retains other arguments',
    () async {
      final self = ResourceControl.forObject(Object());
      final other = ResourceControl.forObject(Object());
      final operation = ResourceOperation(exempt: self);
      operation.retain(null);
      operation.retain(self);
      expect(operation.isEmpty, isTrue);
      operation.retain(other);
      var cleanedOther = false;
      final otherDone = other.dispose(() => cleanedOther = true);
      await self.dispose(() {});
      expect(self.state, ResourceState.closed);
      expect(cleanedOther, isFalse);
      operation.release();
      await otherDone;
      expect(cleanedOther, isTrue);
    },
  );

  test('operation detaches before cleanup reentry', () async {
    final first = ResourceControl.forObject(Object());
    final second = ResourceControl.forObject(Object());
    final operation = ResourceOperation();
    operation.retain(first);
    operation.retain(second);
    var count = 0;
    final a = first.dispose(() => count++);
    final b = second.dispose(() {
      expect(operation.isReleased, isTrue);
      expect(operation.isEmpty, isTrue);
      operation.release();
      expect(() => operation.retain(first), throwsStateError);
      count++;
    });
    operation.release();
    await Future.wait([a, b]);
    expect(count, 2);
  });
}

final class _Wrapper {
  _Wrapper(Object raw) : control = ResourceControl.forObject(raw);

  final ResourceControl control;
}

final class _EqualOwner {
  @override
  bool operator ==(Object other) => other is _EqualOwner;

  @override
  int get hashCode => 0;
}

final class _Resource {
  (String, int)? closed;

  void close(String reason, {int count = 1}) => closed = (reason, count);
}
