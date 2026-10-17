import 'dart:async';
import 'dart:collection';

import 'package:napi/napi.dart';

int Function(int)? _savedCallback;
Object? _savedError;
List<int> _pressure = [];
int _calls = 0;
int _timerState = 0;
int _microtaskState = 0;
final _cleanups = <int, int>{};
final _registrations = <int Function(int)>[];
final _asyncRegistrations = <Future<int> Function(int)>[];
final _weakCallbacks = <WeakReference<Function>>[];

@NAPI()
int callbackCalls() => _calls;

@NAPI()
int callTwice(int Function(int) callback, int value) {
  _calls++;
  return callback(value) + callback(value + 1);
}

@NAPI()
int callMany(int Function(int) callback, int count) {
  var result = 0;
  for (var i = 0; i < count; i++) {
    result += callback(i);
  }
  return result;
}

@NAPI()
String callString(String Function(String) callback, String value) =>
    callback(value);

@NAPI()
BigInt callBigInt(BigInt Function(BigInt) callback, BigInt value) =>
    callback(value);

@NAPI(bigint: true)
int callWide(int Function(int) callback, int value) => callback(value);

@NAPI()
bool callBool(bool Function(bool) callback, bool value) => callback(value);

@NAPI()
double callDouble(double Function(double) callback, double value) =>
    callback(value);

@NAPI()
(List<int>, {String label}) callRecord(
  (List<int>, {String label}) Function((List<int>, {String label})) callback,
  (List<int>, {String label}) value,
) => callback(value);

@NAPI()
List<int> callList(List<int> Function(List<int>) callback) => callback([1, 2]);

@NAPI()
List<List<int?>>? callNested(
  List<List<int?>>? Function(List<List<int?>>?) callback,
  List<List<int?>>? value,
) => callback(value);

@NAPI()
int callbackUnsafeArgument(int Function(int) callback) =>
    callback(9007199254740992);

@NAPI()
int callbackArgumentOrder(int Function(int, List<int>) callback) =>
    callback(9007199254740992, _ThrowingList());

final class _ThrowingList extends ListBase<int> {
  @override
  int get length => 1;
  @override
  set length(int value) => throw StateError('unused');
  @override
  int operator [](int index) => throw StateError('callback argument getter');
  @override
  void operator []=(int index, int value) => throw StateError('unused');
}

@NAPI()
int catchArgumentFailure(int Function(List<int>) callback) {
  try {
    callback(_ThrowingList());
  } catch (_) {
    return 1;
  }
  return 0;
}

@NAPI()
int callVoid(void Function(int) callback) {
  callback(7);
  return 42;
}

@NAPI()
int optionalCallback([int Function(int)? callback]) => callback?.call(3) ?? -1;

@NAPI()
int namedCallback({required int Function(int) callback, int value = 3}) =>
    callback(value);

@NAPI()
int catchAndContinue(int Function(int) first, int Function(int) second) {
  try {
    return first(3);
  } catch (_) {
    return second(5);
  }
}

@NAPI()
int saveThrow(void Function() callback) {
  try {
    callback();
    return 0;
  } catch (error) {
    _savedError = error;
    return 1;
  }
}

@NAPI()
int rethrowSaved() => throw _savedError!;

@NAPI()
Future<int> rethrowSavedFuture() => Future.error(_savedError!);

@NAPI()
int clearSavedError() {
  _savedError = null;
  return 0;
}

@NAPI()
int replaceThrow(int Function(int) callback) {
  try {
    return callback(1);
  } catch (_) {
    throw StateError('replacement Dart error');
  }
}

@NAPI()
int saveCallback(int Function(int) callback) {
  _savedCallback = callback;
  return callback(1);
}

@NAPI()
int invokeSaved() => _savedCallback!(5);

@NAPI()
int clearSavedCallback() {
  _savedCallback = null;
  return 0;
}

@NAPI()
bool sameCallback(int Function(int) first, int Function(int) second) =>
    identical(first, second);

@NAPI()
int registerCallback(int Function(int) callback) {
  _registrations.add(callback);
  return _registrations.length;
}

@NAPI()
bool unregisterCallback(int Function(int) callback) =>
    _registrations.remove(callback);

@NAPI()
int registeredCallbackCount() => _registrations.length;

@NAPI()
int invokeRegistered(int index, int value) => _registrations[index](value);

@NAPI(bigint: true)
bool sameWideCallback(int Function(int) callback) =>
    identical(_registrations.first, callback);

@NAPI()
int rememberCallbackWeakly(int Function(int) callback) {
  _weakCallbacks.add(WeakReference(callback));
  return _weakCallbacks.length;
}

@NAPI()
int weakCallbackCount() =>
    _weakCallbacks.where((entry) => entry.target != null).length;

@NAPI()
int rememberAsyncCallbackWeakly(Future<int> Function(int) callback) {
  _weakCallbacks.add(WeakReference(callback));
  return _weakCallbacks.length - 1;
}

@NAPI()
bool matchesWeakAsyncCallback(int index, Future<int> Function(int) callback) =>
    identical(_weakCallbacks[index].target, callback);

@NAPI()
Future<int> callAfter(int Function(int) callback, int value) async {
  await Future<void>.delayed(Duration.zero);
  return callback(value);
}

@NAPI()
Future<int> callAsync(Future<int> Function(int) callback, int value) =>
    callback(value);

@NAPI()
Future<void> callAsyncVoid(Future<void> Function() callback) => callback();

@NAPI()
Future<String> callAsyncString(
  Future<String> Function(String) callback,
  String value,
) => callback(value);

@NAPI(bigint: true)
Future<int> callAsyncWide(Future<int> Function(int) callback, int value) =>
    callback(value);

@NAPI()
Future<(List<int?>, {String label})> callAsyncRecord(
  Future<(List<int?>, {String label})> Function((List<int?>, {String label}))
  callback,
) => callback(([1, null], label: 'row'));

@NAPI()
Future<int> optionalAsyncCallback([Future<int> Function(int)? callback]) =>
    callback?.call(3) ?? Future.value(-1);

@NAPI()
int registerAsyncCallback(Future<int> Function(int) callback) {
  _asyncRegistrations.add(callback);
  return _asyncRegistrations.length;
}

@NAPI()
bool unregisterAsyncCallback(Future<int> Function(int) callback) =>
    _asyncRegistrations.remove(callback);

@NAPI()
Future<int> invokeAsyncRegistered(int index, int value) =>
    _asyncRegistrations[index](value);

@NAPI()
Future<int> catchAsyncError(Future<void> Function() callback) async {
  try {
    await callback();
    return 0;
  } catch (error) {
    _savedError = error;
    return 1;
  }
}

@NAPI()
int catchCallbackStart(Future<int> Function(int) callback) {
  try {
    callback(1);
    return 0;
  } catch (error) {
    _savedError = error;
    return 1;
  }
}

@NAPI()
int scheduleCallback(int Function(int) callback) {
  _timerState = 0;
  Timer.run(() {
    try {
      callback(9);
      _timerState = -1;
    } catch (_) {
      _timerState = 1;
    }
  });
  return callback(2);
}

@NAPI()
int callbackTimerState() => _timerState;

@NAPI()
int scheduleMicrotaskCallback(int Function(int) callback) {
  _microtaskState = 0;
  scheduleMicrotask(() {
    try {
      callback(9);
      _microtaskState = -1;
    } catch (_) {
      _microtaskState = 1;
    }
  });
  return callback(2);
}

@NAPI()
int callbackMicrotaskState() => _microtaskState;

@NAPI()
int callbackPressure(int seed) {
  _pressure = List<int>.generate(1000000, (index) => seed + index);
  return _pressure.last;
}

@NAPI()
class CallbackBox {
  int _value;
  int Function(int)? _stored;
  CallbackBox(int Function() callback) : _value = callback();
  CallbackBox.named(int Function(int) callback, int initial)
    : _value = callback(initial);
  int get value => _value;
  int apply(int Function(int) callback) => callback(_value);
  set callback(int Function(int) callback) {
    _stored = callback;
    _value = callback(_value);
  }

  int invokeStored() => _stored!(_value);
}

@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class CallbackResource {
  final int id;
  CallbackResource(this.id);
  int apply(int Function(int) callback) => callback(id);
  Future<int> applyAsync(Future<int> Function(int) callback) => callback(id);
  Future<int> applyLater(int Function(int) callback) async {
    await Future<void>.delayed(Duration.zero);
    return callback(id);
  }

  void close() => _cleanups.update(id, (n) => n + 1, ifAbsent: () => 1);
}

@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class CallbackCleanup {
  final int id;
  CallbackCleanup(this.id);
  Future<void> close(Future<void> Function() finish) async {
    try {
      await finish();
    } finally {
      _cleanups.update(id, (n) => n + 1, ifAbsent: () => 1);
    }
  }
}

@NAPI()
int callbackCleanups(int id) => _cleanups[id] ?? 0;

// Selected independently through ExternalLibrary without changing the library.
int plainCallback(int Function(int) callback, int value) => callback(value);

Future<int> plainAsyncCallback(Future<int> Function(int) callback, int value) =>
    callback(value);
