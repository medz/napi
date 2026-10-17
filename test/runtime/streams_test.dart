import 'dart:async';

import 'package:napi/runtime.dart';
import 'package:test/test.dart';

NapiStream<T, _Box<T>> _binding<T>(
  Stream<T> source, {
  List<Object?> roots = const [],
  ResourceOperation? operation,
  void Function(_Box<T>)? release,
  bool publish = true,
}) {
  final state = NapiStream<T, _Box<T>>(
    source,
    snapshot: _Box.new,
    releaseSnapshot: release,
    roots: roots,
    operation: operation,
  );
  if (publish) state.finishCreation(true);
  return state;
}

Future<void> _turns() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.value();
  }
}

void main() {
  test('lazy return never listens and keeps roots through delivery acknowledgement', () async {
    var listens = 0;
    final source = StreamController<int>(onListen: () => listens++);
    final root = Object();
    final state = _binding(source.stream, roots: [root]);
    final roots = state.retainedInputs;
    expect(roots, same(state.retainedInputs));
    final first = await state.return_();
    expect(listens, 0);
    expect(first.kind, StreamDeliveryKind.done);
    expect(roots, [root]);
    first.release();
    first.release();
    expect(first.isReleased, isTrue);
    expect(roots, isEmpty);
    final again = await state.return_();
    expect(again.kind, StreamDeliveryKind.done);
    again.release();
    final after = await state.next();
    expect(after.kind, StreamDeliveryKind.done);
    after.release();
  });

  test(
    'concurrent reads pair FIFO and single streams pause only without demand',
    () async {
      var pauses = 0, resumes = 0;
      final source = StreamController<int>(
        sync: true,
        onPause: () => pauses++,
        onResume: () => resumes++,
      );
      final dropped = <int>[];
      final state = _binding(
        source.stream,
        release: (box) => dropped.add(box.value),
      );
      final a = state.next(), b = state.next(), c = state.next();
      source.add(1);
      source.add(2);
      source.add(3);
      final deliveries = await Future.wait([a, b, c]);
      expect(deliveries.map((d) => d.value!.value), [1, 2, 3]);
      expect(pauses, 1);
      for (final item in deliveries) {
        item.release();
      }
      final next = state.next();
      expect(resumes, 1);
      source.add(4);
      (await next).release();
      expect(dropped, [1, 2, 3, 4]);
      (await state.return_()).release();
      await source.close();
    },
  );

  test('async generators and normal completion drain before done', () async {
    Stream<int> source() async* {
      yield 1;
      yield 2;
    }

    final state = _binding(source(), roots: [Object()]);
    final items = await Future.wait([state.next(), state.next(), state.next()]);
    expect(items.map((d) => d.kind), [
      StreamDeliveryKind.value,
      StreamDeliveryKind.value,
      StreamDeliveryKind.done,
    ]);
    expect(items.take(2).map((d) => d.value!.value), [1, 2]);
    expect(state.retainedInputs, isNotEmpty);
    for (final item in items) {
      item.release();
    }
    expect(state.retainedInputs, isEmpty);
  });

  test('broadcast capacity is 64 queued items and overflow follows admitted values', () async {
    var cancellations = 0;
    final source = StreamController<int>.broadcast(
      sync: true,
      onCancel: () => cancellations++,
    );
    final state = _binding(source.stream);
    final initial = state.next();
    source.add(0);
    for (var i = 1; i <= 65; i++) {
      source.add(i);
    }
    (await initial).release();
    for (var i = 1; i <= 64; i++) {
      final item = await state.next();
      expect(item.kind, StreamDeliveryKind.value);
      expect(item.value!.value, i);
      item.release();
    }
    final error = await state.next();
    expect(error.kind, StreamDeliveryKind.error);
    expect(error.error, isA<StreamBufferOverflow>());
    error.release();
    final done = await state.next();
    expect(done.kind, StreamDeliveryKind.done);
    done.release();
    expect(cancellations, 1);
    await source.close();
  });

  test(
    'snapshot runs at admission and a conversion error preserves earlier items',
    () async {
      final source = StreamController<List<int>>.broadcast(sync: true);
      final exact = StateError('snapshot');
      final stack = StackTrace.fromString('snapshot stack');
      final state = NapiStream<List<int>, List<int>>(
        source.stream,
        snapshot: (value) {
          if (value.isEmpty) Error.throwWithStackTrace(exact, stack);
          return List.of(value);
        },
        roots: [],
      )..finishCreation(true);
      final first = state.next();
      source.add([0]);
      final mutable = [1];
      source.add(mutable);
      mutable[0] = 99;
      source.add([]);
      source.add([2]);
      (await first).release();
      final item = await state.next();
      expect(item.value, [1]);
      item.release();
      final error = await state.next();
      expect(error.error, same(exact));
      expect(error.stack.toString(), stack.toString());
      error.release();
      final done = await state.next();
      expect(done.kind, StreamDeliveryKind.done);
      done.release();
      await source.close();
    },
  );

  test('first source error wins while explicit return retains its cancellation error', () async {
    final sourceError = StateError('source'),
        cancelError = StateError('cancel');
    final source = StreamController<int>(
      sync: true,
      onCancel: () => Future<void>.error(cancelError),
    );
    final state = _binding(source.stream);
    final next = state.next();
    source.addError(sourceError);
    final item = await next;
    expect(item.error, same(sourceError));
    item.release();
    final returned = await state.return_();
    expect(returned.error, same(cancelError));
    returned.release();
    final repeated = await state.return_();
    expect(repeated.error, same(cancelError));
    repeated.release();
    await source.close();
  });

  test(
    'return waits for cancellation and preserves already accepted deliveries',
    () async {
      final cancellation = Completer<void>();
      final custom = _Stream<int>(
        (data, error, done) => _Subscription<int>(
          onCancel: () => cancellation.future,
          onListen: () {
            data(1);
            data(2);
          },
        ),
      );
      final released = <int>[];
      final state = _binding(
        custom,
        roots: [Object()],
        release: (box) => released.add(box.value),
      );
      final first = state.next();
      final returned = state.return_();
      var returnedDone = false;
      returned.then((_) => returnedDone = true);
      await _turns();
      expect(returnedDone, isFalse);
      // First item was paired during next(); the still queued second is discarded.
      expect(released, [2]);
      cancellation.complete();
      await _turns();
      expect(
        returnedDone,
        isFalse,
        reason: 'return waits for accepted delivery ack',
      );
      expect(state.retainedInputs, isNotEmpty);
      final accepted = await first;
      expect(accepted.value!.value, 1);
      accepted.release();
      final done = await returned;
      done.release();
      expect(released, [2, 1]);
      expect(state.retainedInputs, isEmpty);
    },
  );

  test('pending reads finish done after return cancellation', () async {
    final gate = Completer<void>();
    final source = StreamController<int>(onCancel: () => gate.future);
    final state = _binding(source.stream);
    final pending = [state.next(), state.next()];
    final returned = state.return_();
    gate.complete();
    for (final value in await Future.wait(pending)) {
      expect(value.kind, StreamDeliveryKind.done);
      value.release();
    }
    final done = await returned;
    expect(done.kind, StreamDeliveryKind.done);
    done.release();
    await source.close();
  });

  test(
    'concurrent returns wait for earlier delivery but not each other',
    () async {
      final gate = Completer<void>();
      var cancels = 0;
      final source = StreamController<int>(
        sync: true,
        onCancel: () {
          cancels++;
          return gate.future;
        },
      );
      final state = _binding(source.stream, roots: [Object()]);
      final read = state.next();
      source.add(1);
      final accepted = await read;
      final first = state.return_(), second = state.return_();
      var completed = 0;
      first.then((_) => completed++);
      second.then((_) => completed++);
      gate.complete();
      await _turns();
      expect(completed, 0);
      accepted.release();
      final returns = await Future.wait([first, second]);
      expect(
        returns.map((item) => item.kind),
        everyElement(StreamDeliveryKind.done),
      );
      expect(cancels, 1);
      expect(state.retainedInputs, isNotEmpty);
      returns.first.release();
      expect(state.retainedInputs, isNotEmpty);
      returns.last.release();
      expect(state.retainedInputs, isEmpty);
      await source.close();
    },
  );

  test(
    'late close waits for creation and never starts a subscription',
    () async {
      final control = ResourceControl.forObject(Object());
      final operation = ResourceOperation()..retain(control);
      var cleaned = false, listened = false;
      final disposed = control.dispose(() => cleaned = true);
      final source = StreamController<int>(onListen: () => listened = true);
      final state = _binding(
        source.stream,
        operation: operation,
        roots: [Object()],
        publish: false,
      );
      await _turns();
      expect(cleaned, isFalse);
      state.finishCreation(true);
      await disposed;
      expect(cleaned, isTrue);
      expect(listened, isFalse);
      expect(state.retainedInputs, isEmpty);
    },
  );

  test(
    'close during listen waits for returned subscription and delivery ack',
    () async {
      final control = ResourceControl.forObject(Object());
      final operation = ResourceOperation()..retain(control);
      final events = <String>[];
      final gate = Completer<void>();
      late Future<void> disposed;
      final source = _Stream<int>((data, error, done) {
        events.add('listen');
        disposed = control.dispose(() => events.add('cleanup'));
        expect(events, ['listen']);
        return _Subscription<int>(
          onCancel: () {
            events.add('cancel');
            return gate.future;
          },
        );
      });
      final state = _binding(source, operation: operation);
      final read = state.next();
      expect(events, ['listen', 'cancel']);
      gate.complete();
      final done = await read;
      expect(events, ['listen', 'cancel']);
      done.release();
      await disposed;
      expect(events, ['listen', 'cancel', 'cleanup']);
    },
  );

  test(
    'snapshot reentrant close cannot release inputs during conversion',
    () async {
      final control = ResourceControl.forObject(Object());
      final operation = ResourceOperation()..retain(control);
      var cleaned = false;
      late Future<void> disposed;
      final source = StreamController<int>.broadcast(sync: true);
      final state = NapiStream<int, _Box<int>>(
        source.stream,
        snapshot: (value) {
          disposed = control.dispose(() => cleaned = true);
          expect(cleaned, isFalse);
          expect(operation.isReleased, isFalse);
          return _Box(value);
        },
        roots: [Object()],
        operation: operation,
      )..finishCreation(true);
      final read = state.next();
      source.add(1);
      final done = await read;
      expect(done.kind, StreamDeliveryKind.done);
      expect(cleaned, isFalse);
      done.release();
      await disposed;
      expect(cleaned, isTrue);
      await source.close();
    },
  );

  test(
    'owner close reports first cancellation failure by registration order',
    () async {
      final control = ResourceControl.forObject(Object());
      final a = Completer<void>(), b = Completer<void>();
      final firstError = StateError('registered first');
      final secondError = StateError('registered second');
      var cleaned = 0;
      final states = [
        for (final gate in [a, b])
          _binding(
            StreamController<int>(onCancel: () => gate.future).stream,
            operation: ResourceOperation()..retain(control),
          ),
      ];
      final reads = [for (final state in states) state.next()];
      final disposed = control.dispose(() => cleaned++);
      final observed = expectLater(disposed, throwsA(same(firstError)));
      b.completeError(secondError);
      a.completeError(firstError);
      for (final read in reads) {
        (await read).release();
      }
      await observed;
      expect(cleaned, 1);
      expect(control.state, ResourceState.closed);
    },
  );

  for (final asynchronous in [false, true]) {
    test(
      'business cleanup error wins over cancellation (${asynchronous ? 'async' : 'sync'})',
      () async {
        final control = ResourceControl.forObject(Object());
        final cancelError = StateError('cancel'),
            cleanupError = StateError('cleanup');
        final source = StreamController<int>(
          onCancel: () => Future<void>.error(cancelError),
        );
        final state = _binding(
          source.stream,
          operation: ResourceOperation()..retain(control),
        );
        final read = state.next();
        var calls = 0;
        final disposed = control.dispose(() {
          calls++;
          if (asynchronous) return Future<void>.error(cleanupError);
          throw cleanupError;
        });
        final observed = expectLater(disposed, throwsA(same(cleanupError)));
        (await read).release();
        await observed;
        expect(calls, 1);
        final returned = await state.return_();
        expect(returned.error, same(cancelError));
        returned.release();
        await source.close();
      },
    );
  }

  test(
    'a failed delivery cancels without reporting its rejection twice',
    () async {
      var cancels = 0;
      final source = StreamController<int>(
        sync: true,
        onCancel: () => cancels++,
      );
      final state = _binding(source.stream, roots: [Object()]);
      final read = state.next();
      source.add(1);
      final item = await read;
      state.deliveryFailed(StateError('transport'), StackTrace.current);
      item.release();
      final done = await state.next();
      expect(done.kind, StreamDeliveryKind.done);
      done.release();
      expect(cancels, 1);
      expect(state.retainedInputs, isEmpty);
      await source.close();
    },
  );

  test(
    'cancel errors are zone-intercepted once across return and owner close',
    () async {
      var interceptions = 0;
      final original = StateError('original');
      final rewritten = StateError('rewritten');
      final rewrittenStack = StackTrace.fromString(
        'rewritten cancellation stack',
      );
      await runZoned(
        () async {
          final control = ResourceControl.forObject(Object());
          final source = StreamController<int>(
            onCancel: () => Future<void>.error(original),
          );
          final state = _binding(
            source.stream,
            operation: ResourceOperation()..retain(control),
          );
          final pending = state.next();
          final disposed = control.dispose(() {});
          final observed = disposed.then<void>(
            (_) => fail('must reject'),
            onError: (Object error, StackTrace stack) {
              expect(error, same(rewritten));
              expect(stack.toString(), rewrittenStack.toString());
            },
          );
          (await pending).release();
          await observed;
          final returned = await state.return_();
          expect(returned.error, same(rewritten));
          expect(returned.stack.toString(), rewrittenStack.toString());
          returned.release();
          await source.close();
        },
        zoneSpecification: ZoneSpecification(
          errorCallback: (self, parent, zone, error, stack) {
            interceptions++;
            return AsyncError(rewritten, rewrittenStack);
          },
        ),
      );
      expect(interceptions, 1);
    },
  );

  test(
    'one stream notifies every distinct input control and cancels once',
    () async {
      final a = ResourceControl.forObject(Object()),
          b = ResourceControl.forObject(Object());
      final operation = ResourceOperation()
        ..retain(a)
        ..retain(a)
        ..retain(b);
      final gate = Completer<void>();
      var cancels = 0, cleaned = 0;
      final source = StreamController<int>(
        onCancel: () {
          cancels++;
          return gate.future;
        },
      );
      final state = _binding(source.stream, operation: operation);
      final pending = state.next();
      final first = a.dispose(() => cleaned++),
          second = b.dispose(() => cleaned++);
      expect(cancels, 1);
      expect(cleaned, 0);
      gate.complete();
      (await pending).release();
      await Future.wait([first, second]);
      expect(cleaned, 2);
      expect(operation.isReleased, isTrue);
      await source.close();
    },
  );

  test(
    'return discards queued values but does not swallow the first source error',
    () async {
      final source = StreamController<int>.broadcast(sync: true);
      final state = _binding(source.stream);
      final initial = state.next();
      source.add(0);
      source.add(1);
      final exact = StateError('source before return');
      source.addError(exact);
      (await initial).release();
      (await state.return_()).release();
      final error = await state.next();
      expect(error.error, same(exact));
      error.release();
      expect(
        error.error,
        isNull,
        reason: 'acknowledged delivery drops error roots',
      );
      final done = await state.next();
      expect(done.kind, StreamDeliveryKind.done);
      done.release();
      await source.close();
    },
  );

  test(
    'failed facade adoption releases unstarted inputs without listening',
    () async {
      final control = ResourceControl.forObject(Object());
      final operation = ResourceOperation()..retain(control);
      var listens = 0;
      final source = StreamController<int>(onListen: () => listens++);
      final state = _binding(
        source.stream,
        operation: operation,
        roots: [Object()],
        publish: false,
      );
      final disposed = control.dispose(() {});
      state.finishCreation(false);
      await disposed;
      expect(listens, 0);
      expect(state.retainedInputs, isEmpty);
    },
  );

  test('listen failure is an acknowledged first read error', () async {
    final exact = StateError('listen');
    final state = _binding(
      _Stream<int>((data, error, done) => throw exact),
      roots: [Object()],
    );
    final error = await state.next();
    expect(error.error, same(exact));
    expect(state.retainedInputs, isNotEmpty);
    error.release();
    await _turns();
    expect(state.retainedInputs, isEmpty);
  });

  test('synchronous resume reentry supplies the pending read', () async {
    late void Function(int) send;
    final subscription = _Subscription<int>(onCancel: () async {});
    final state = _binding(
      _Stream<int>((data, error, done) {
        send = data;
        return subscription;
      }),
    );
    final first = state.next();
    send(1);
    (await first).release();
    subscription.onResume = () => send(2);
    final next = await state.next();
    expect(next.value!.value, 2);
    next.release();
    (await state.return_()).release();
  });

  test(
    'a non-cooperative source remains subject to the same adapter cap',
    () async {
      late void Function(int) send;
      final state = _binding(
        _Stream<int>((data, error, done) {
          send = data;
          return _Subscription(onCancel: () async {});
        }),
      );
      final first = state.next();
      send(0);
      (await first).release();
      for (var i = 1; i <= 65; i++) {
        send(i);
      }
      for (var i = 1; i <= 64; i++) {
        final next = await state.next();
        expect(next.value!.value, i);
        next.release();
      }
      final error = await state.next();
      expect(error.error, isRangeError);
      error.release();
    },
  );
}

final class _Box<T> {
  _Box(this.value);
  final T value;
}

final class _Stream<T> extends Stream<T> {
  _Stream(this.listen_);
  final StreamSubscription<T> Function(
    void Function(T),
    void Function(Object, StackTrace),
    void Function(),
  )
  listen_;
  @override
  StreamSubscription<T> listen(
    void Function(T)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final subscription = listen_(
      onData!,
      onError as void Function(Object, StackTrace),
      onDone!,
    );
    if (subscription is _Subscription<T>) subscription.onListen?.call();
    return subscription;
  }
}

final class _Subscription<T> implements StreamSubscription<T> {
  _Subscription({required this.onCancel, this.onListen});
  final Future<void> Function() onCancel;
  final void Function()? onListen;
  void Function()? onResume;
  @override
  Future<void> cancel() => onCancel();
  @override
  bool isPaused = false;
  @override
  void pause([Future<void>? resumeSignal]) => isPaused = true;
  @override
  void resume() {
    isPaused = false;
    onResume?.call();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
