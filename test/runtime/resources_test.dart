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
