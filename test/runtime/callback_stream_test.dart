import 'dart:async';

import 'package:napi/runtime.dart';
import 'package:test/test.dart';

Future<void> turns() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.value();
  }
}

void main() {
  test('iteration failure is preserved when return also fails', () async {
    final original = StateError('next');
    final cleanup = StateError('return');
    final source = NapiCallbackStream<int>(
      next: () => Future.error(original),
      close: () => Future.error(cleanup),
    );
    await expectLater(source.stream.toList(), throwsA(same(original)));
    await turns();
  });

  test(
    'single subscription pulls lazily, pauses and ends without return',
    () async {
      var reads = 0;
      var returns = 0;
      final source = NapiCallbackStream<int>(
        next: () async => ++reads < 3
            ? CallbackStreamItem.value(reads)
            : const CallbackStreamItem.done(),
        close: () async {
          returns++;
        },
      );
      await turns();
      expect(reads, 0);
      final values = <int>[];
      final done = Completer<void>();
      late StreamSubscription<int> subscription;
      subscription = source.stream.listen((value) {
        values.add(value);
        if (value == 1) subscription.pause();
      }, onDone: done.complete);
      await turns();
      expect(values, [1]);
      expect(reads, 1);
      subscription.resume();
      await done.future;
      expect(values, [1, 2]);
      expect(reads, 3);
      expect(returns, 0);
      expect(() => source.stream.listen((_) {}), throwsStateError);
    },
  );

  test(
    'resource close returns an unlistened iterator before cleanup',
    () async {
      final control = ResourceControl.forObject(Object());
      final operation = ResourceOperation()..retain(control);
      final returned = Completer<void>();
      var reads = 0;
      var returns = 0;
      var cleaned = false;
      final source = NapiCallbackStream<int>(
        next: () async {
          reads++;
          return const CallbackStreamItem.value(1);
        },
        close: () {
          returns++;
          return returned.future;
        },
        operation: operation,
      );
      final closing = control.dispose(() => cleaned = true);
      expect(returns, 1);
      expect(reads, 0);
      expect(cleaned, isFalse);
      expect(source.cancel(), same(source.cancel()));
      returned.complete();
      await closing;
      expect(cleaned, isTrue);
      expect(await source.stream.toList(), isEmpty);
      expect(reads, 0);
    },
  );
}
