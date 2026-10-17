import 'dart:async';

import 'package:napi/runtime.dart';
import 'package:test/test.dart';

Future<void> _turns() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.value();
  }
}

void main() {
  test(
    'one lazy host registration detaches immediately after last removal',
    () {
      final signal = _Signal();
      expect(signal.arms, 0);
      final first = signal.onAbort(() {}), second = signal.onAbort(() {});
      expect(signal.arms, 1);
      first();
      first();
      expect(signal.disarms, 0);
      second();
      expect(signal.disarms, 1);
      signal.onAbort(() {})();
      expect(signal.arms, 2);
      expect(signal.disarms, 2);
    },
  );

  test(
    'abort is asynchronous, once per registration, and removal suppresses it',
    () async {
      final signal = _Signal();
      var calls = 0;
      void listener() => calls++;
      signal.onAbort(listener);
      signal.onAbort(listener);
      final removed = signal.onAbort(listener);
      signal.abort();
      expect(signal.disarms, 1);
      expect(calls, 0);
      removed();
      signal.notifyAbort();
      await _turns();
      expect(calls, 2);
      signal.notifyAbort();
      await _turns();
      expect(calls, 2);
    },
  );

  test(
    'late registrations queue once and can be removed before notification',
    () async {
      final signal = _Signal()..abort();
      var calls = 0;
      signal.onAbort(() => calls++);
      signal.onAbort(() => calls++)();
      expect(calls, 0);
      expect(signal.arms, 0);
      await _turns();
      expect(calls, 1);
      signal.notifyAbort();
      await _turns();
      expect(calls, 1);
    },
  );

  test(
    'fresh aborted state catches an abort before the owner event arrives',
    () async {
      final signal = _Signal();
      final calls = <int>[];
      signal.onAbort(() => calls.add(1));
      signal.requested = true;
      expect(signal.aborted, isTrue);
      expect(signal.throwIfAborted, throwsA(same(signal.reason)));
      signal.onAbort(() => calls.add(2));
      signal.notifyAbort();
      await _turns();
      expect(calls, [1, 2]);
      expect(signal.disarms, 1);
    },
  );

  test('false notifications do not consume or invoke registrations', () async {
    final signal = _Signal();
    var calls = 0;
    signal.onAbort(() => calls++);
    signal.notifyAbort();
    await _turns();
    expect(calls, 0);
    expect(signal.disarms, 0);
    signal.abort();
    await _turns();
    expect(calls, 1);
  });

  test(
    'each listener uses its registration zone and errors do not stop others',
    () async {
      final signal = _Signal();
      final exact = StateError('listener');
      final stack = StackTrace.fromString('listener stack');
      final failure = Completer<(Object, StackTrace)>();
      var calls = 0;
      runZonedGuarded(
        () => signal.onAbort(() {
          expect(Zone.current[#registration], 42);
          Error.throwWithStackTrace(exact, stack);
        }),
        (error, trace) => failure.complete((error, trace)),
        zoneValues: {#registration: 42},
      );
      signal.onAbort(() => calls++);
      signal.abort();
      final (error, trace) = await failure.future;
      expect(error, same(exact));
      expect(trace.toString(), stack.toString());
      await _turns();
      expect(calls, 1);
    },
  );

  test(
    'a listener can remove another queued listener and register a late one',
    () async {
      final signal = _Signal();
      final calls = <int>[];
      late void Function() remove;
      signal.onAbort(() {
        calls.add(1);
        remove();
        signal.onAbort(() => calls.add(3));
        expect(calls, [1]);
      });
      remove = signal.onAbort(() => calls.add(2));
      signal.abort();
      await _turns();
      expect(calls, [1, 3]);
    },
  );

  test(
    'abort during host arm cannot miss or repeat its registration',
    () async {
      final signal = _Signal();
      signal.onArm = signal.abort;
      var calls = 0;
      signal.onAbort(() => calls++);
      expect(calls, 0);
      expect(signal.arms, 1);
      expect(signal.disarms, 1);
      await _turns();
      expect(calls, 1);
    },
  );

  test(
    'failed arm removes its listener and a later registration can retry',
    () async {
      final signal = _Signal();
      final exact = StateError('arm');
      signal.onArm = () => throw exact;
      var calls = 0;
      expect(() => signal.onAbort(() => calls++), throwsA(same(exact)));
      expect(signal.disarms, 1);
      signal.onArm = null;
      signal.onAbort(() => calls++);
      signal.abort();
      await _turns();
      expect(signal.arms, 2);
      expect(calls, 1);
    },
  );
}

final class _Signal extends NapiAbortSignal {
  bool requested = false;
  int arms = 0, disarms = 0;
  final Object reason = StateError('abort');
  void Function()? onArm;

  void abort() {
    requested = true;
    notifyAbort();
  }

  @override
  bool get aborted => requested;
  @override
  void throwIfAborted() {
    if (requested) throw reason;
  }

  @override
  void armAbort() {
    arms++;
    onArm?.call();
  }

  @override
  void disarmAbort() => disarms++;
}
