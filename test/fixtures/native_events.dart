import 'dart:async';
import 'dart:isolate';

import 'package:napi/napi.dart';

final _events = <String>[];
Timer? _timer;
Completer<void>? _pending;

@NAPI()
String readEvents() => _events.join(',');

@NAPI()
void enqueueMicrotasks() {
  _events.add('sync');
  scheduleMicrotask(() {
    _events.add('microtask');
    scheduleMicrotask(() => _events.add('nested'));
  });
  Future<void>.value().then((_) => _events.add('future'));
  scheduleMicrotask(() => _events.add('last'));
}

@NAPI()
void startTimer(int milliseconds, String label) {
  _timer?.cancel();
  _timer = Timer(Duration(milliseconds: milliseconds), () {
    _timer = null;
    _events.add(label);
    print('native-events:$label');
  });
}

@NAPI()
void timerFromMicrotask() {
  scheduleMicrotask(() {
    _events.add('before-timer');
    startTimer(30, 'microtask-timer');
  });
}

@NAPI()
void cancelTimerLater() {
  Timer(const Duration(milliseconds: 30), () {
    _timer?.cancel();
    _timer = null;
    _events.add('cancelled');
    print('native-events:cancelled');
  });
}

@NAPI()
void orderedTimers() {
  Timer(Duration.zero, () {
    _events.add('zero');
    scheduleMicrotask(() => _events.add('after-zero'));
  });
  startTimer(30, 'later');
}

@NAPI()
void sendMessages(int count) {
  if (count < 1 || count > 4096) throw RangeError.range(count, 1, 4096);
  final port = ReceivePort();
  port.listen((message) {
    final index = message as int;
    _events.add('m$index');
    scheduleMicrotask(() => _events.add('u$index'));
    if (index == count - 1) {
      port.close();
      scheduleMicrotask(() => print('native-events:messages-complete'));
    }
  });
  for (var index = 0; index < count; index++) {
    port.sendPort.send(index);
  }
}

@NAPI()
void leaveFuturePending() {
  _pending = Completer<void>();
  _pending!.future.then((_) => _events.add('unexpected-completion'));
  _events.add('pending');
}

@NAPI()
void throwAfterMicrotask() {
  scheduleMicrotask(() => _events.add('after-sync-error'));
  throw StateError('native-events-sync-error');
}

@NAPI()
void failMicrotaskChain() {
  scheduleMicrotask(() => throw StateError('native-events-microtask-error'));
  scheduleMicrotask(() {
    _events.add('after-async-error');
    print('native-events:after-async-error');
  });
}

@NAPI()
void failTimer() {
  Timer(Duration.zero, () => throw StateError('native-events-timer-error'));
}

void main() => throw StateError('Business main must not run');
