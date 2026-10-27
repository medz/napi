import 'dart:async';

import 'package:napi/napi.dart';

@NAPI()
Stream<int> numbers(int count, [int milliseconds = 0]) async* {
  for (var value = 0; value < count; value++) {
    if (milliseconds != 0) {
      await Future<void>.delayed(Duration(milliseconds: milliseconds));
    }
    yield value;
  }
}

@NAPI()
Stream<int> failingValues() async* {
  yield 1;
  throw StateError('stream failed');
}

@NAPI()
Future<List<int>> collect(Stream<int> values) => values.toList();

@NAPI()
Future<List<int>> pauseAfterFirst(
  Stream<int> values,
  void Function() paused,
  Future<void> resume,
) {
  final result = Completer<List<int>>();
  final collected = <int>[];
  late StreamSubscription<int> subscription;
  subscription = values.listen(
    (value) {
      collected.add(value);
      if (collected.length == 1) {
        subscription.pause(resume);
        paused();
      }
    },
    onError: (Object error, StackTrace stack) =>
        result.completeError(error, stack),
    onDone: () => result.complete(collected),
  );
  return result.future;
}

@NAPI()
Future<int> cancelPending(Stream<int> values, Future<void> cancel) async {
  var received = 0;
  final subscription = values.listen((_) => received++);
  await cancel;
  await subscription.cancel();
  return received;
}

@NAPI()
Future<void> delay() => Future<void>.delayed(Duration.zero);

@NAPI()
Stream<int>? nullableStream([Stream<int>? values]) => values;

@NAPI()
Stream<int?> nullableValues() async* {
  yield 1;
  yield null;
}

@NAPI()
Stream<void> voidValues() async* {
  yield null;
  yield null;
}

@NAPI()
Future<int> countVoids(Stream<void> values) async {
  var count = 0;
  await for (final _ in values) {
    count++;
  }
  return count;
}

@NAPI()
class StreamValue {
  @NAPI()
  StreamValue(this.value);
  @NAPI()
  int value;
}

@NAPI()
Stream<StreamValue?> repeatValue(StreamValue value) async* {
  yield value;
  yield null;
  yield value;
}

@NAPI()
class StreamState {
  @NAPI()
  StreamState();

  @NAPI()
  bool started = false;
  @NAPI()
  bool finished = false;
  @NAPI()
  int emitted = 0;

  @NAPI()
  Stream<int> unsafeValues() async* {
    try {
      yield 9007199254740992;
    } finally {
      finished = true;
    }
  }

  @NAPI()
  Stream<int> values([int count = 3, int milliseconds = 0]) async* {
    started = true;
    try {
      for (var value = 0; value < count; value++) {
        if (milliseconds != 0) {
          await Future<void>.delayed(Duration(milliseconds: milliseconds));
        }
        emitted++;
        yield value;
      }
    } finally {
      finished = true;
    }
  }
}

@NAPI()
Future<List<int>> collectFactory(Stream<int> Function() factory) =>
    factory().toList();

@NAPI()
Stream<int> Function(int) numberFactory() => numbers;

@NAPI()
List<Stream<int>> streamList(List<Stream<int>> values) => values;

@NAPI()
Stream<Future<int>> futureValues() => Stream.value(Future.value(7));

@NAPI()
Future<int> sumFutureValues(Stream<Future<int>> values) async {
  var sum = 0;
  await for (final value in values) {
    sum += await value;
  }
  return sum;
}
