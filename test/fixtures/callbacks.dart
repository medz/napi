import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

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
Uint8List callBytes(Uint8List Function(Uint8List) callback, Uint8List value) {
  final result = callback(value);
  if (value.isNotEmpty) value[0] = 90;
  if (result.isNotEmpty) result[0]++;
  return result;
}

@NAPI()
ByteBuffer callBuffer(
  ByteBuffer Function(ByteBuffer) callback,
  ByteBuffer value,
) {
  final result = callback(value);
  final source = value.asUint8List();
  final bytes = result.asUint8List();
  if (source.isNotEmpty) source[0] = 90;
  if (bytes.isNotEmpty) bytes[0]++;
  return result;
}

@NAPI()
SharedBytes? callShared(
  SharedBytes? Function(SharedBytes?) callback,
  SharedBytes? value,
) {
  final result = callback(value);
  if (value != null && value.length > 0) value[0]++;
  return result;
}

typedef CallbackBinary = ({
  List<Uint8List?> bytes,
  ByteBuffer? buffer,
  SharedBytes? shared,
});

CallbackBinary Function(CallbackBinary)? _binaryCallback;

@NAPI()
CallbackBinary callBinaryRecord(
  CallbackBinary Function(CallbackBinary) callback,
  CallbackBinary value,
) {
  _binaryCallback = callback;
  return callback(value);
}

@NAPI()
CallbackBinary invokeBinaryRecord(CallbackBinary value) =>
    _binaryCallback!(value);

@NAPI()
int clearBinaryCallback() {
  _binaryCallback = null;
  return 0;
}

@NAPI()
Future<Uint8List?> callAsyncBytes(
  Future<Uint8List?> Function(Uint8List?) callback,
  Uint8List? value,
) async {
  final result = await callback(value);
  if (value != null && value.isNotEmpty) value[0] = 90;
  if (result != null && result.isNotEmpty) result[0]++;
  return result;
}

@NAPI()
Future<SharedBytes?> callAsyncShared(
  Future<SharedBytes?> Function(SharedBytes?) callback,
  SharedBytes? value,
) async {
  final result = await callback(value);
  if (value != null && value.length > 0) value[0]++;
  if (result != null && result.length > 0) result[0]++;
  return result;
}

@NAPI()
Future<CallbackBinary> callAsyncBinaryRecord(
  Future<CallbackBinary> Function(CallbackBinary) callback,
  CallbackBinary value,
) => callback(value);

@NAPI()
bool binaryCallbackPolicies(
  Uint8List Function(Uint8List) first,
  Uint8List Function(Uint8List) again,
  ByteBuffer Function(ByteBuffer) buffer,
  SharedBytes Function(SharedBytes) shared,
) =>
    identical(first, again) &&
    !identical(first, buffer) &&
    !identical(first, shared);

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

JsArray<int>? _callbackArray;
Function? _handleSignature;

@NAPI()
JsArray<int> callHandle(
  JsArray<int> Function(JsArray<int>) callback,
  JsArray<int> value,
) {
  _handleSignature = callback;
  return _callbackArray = callback(value);
}

@NAPI()
int? readCallbackHandle(int index) => _callbackArray!.get(index);

@NAPI()
int clearCallbackHandle() {
  _callbackArray = null;
  _handleSignature = null;
  return 0;
}

typedef CallbackHandles = ({
  List<JsArray<int>?> arrays,
  JsMap<String, int?> map,
});

@NAPI()
CallbackHandles callHandles(
  CallbackHandles Function(CallbackHandles) callback,
  CallbackHandles value,
) => callback(value);

@NAPI()
JsArray<int>? callNullableHandle(
  JsArray<int>? Function(JsArray<int>?) callback,
  JsArray<int>? value,
) => callback(value);

@NAPI()
Future<JsArray<int>> callAsyncHandle(
  Future<JsArray<int>> Function(JsArray<int>) callback,
  JsArray<int> value,
) async {
  final result = await callback(value);
  value.set(0, value.get(0)! + 1);
  return _callbackArray = result;
}

@NAPI(bigint: true)
JsArray<int> callWideHandle(
  JsArray<int> Function(JsArray<int>) callback,
  JsArray<int> value,
) {
  final result = callback(value);
  result.set(0, result.get(0)!);
  return result;
}

@NAPI()
bool sameHandleSignature(JsArray<int> Function(JsArray<int>) callback) =>
    identical(_handleSignature, callback);

@NAPI(bigint: true)
bool sameWideHandleSignature(JsArray<int> Function(JsArray<int>) callback) =>
    identical(_handleSignature, callback);

@NAPI()
bool sameOpaqueHandleSignature<T>(JsArray<T> Function(JsArray<T>) callback) =>
    identical(_handleSignature, callback);

typedef CallbackPayloads<T> = ({List<JsArray<T>> arrays, JsMap<T, T> map});

@NAPI()
CallbackPayloads<T> callPayloadHandles<T>(
  CallbackPayloads<T> Function(CallbackPayloads<T>) callback,
  CallbackPayloads<T> value,
) => callback(value);

final class _FakeCallbackArray implements JsArray<int> {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

@NAPI(bigint: true)
int callbackHandleOrder(
  int Function(JsArray<int>, List<int>) callback,
  bool fake,
  bool throwing,
) => callback(
  fake ? _FakeCallbackArray() : _callbackArray!,
  throwing ? _ThrowingList() : [1],
);

@NAPI(classPolicy: ClassPolicy.value)
class CallbackValue {
  final int value;
  final int step;
  CallbackValue(this.value, {this.step = 7}) {
    if (value < 0) throw StateError('callback value constructor rejected');
  }

  @NAPI(exclude: true)
  @override
  int get hashCode => value;
  @override
  bool operator ==(Object other) =>
      other is CallbackValue && other.value == value;
}

@NAPI(classPolicy: ClassPolicy.value)
class CallbackNormalized {
  final int value;
  CallbackNormalized.parse(String source) : value = int.parse(source);
}

@NAPI(classPolicy: ClassPolicy.value)
class CallbackSelectedValue {
  final int value;
  final int offset;
  CallbackSelectedValue(this.value) : offset = -100;

  @NAPI()
  CallbackSelectedValue.parse(int source, {this.offset = 7})
    : value = source + offset {
    if (source < 0) {
      throw ArgumentError('selected value source must be nonnegative');
    }
  }
}

@NAPI()
CallbackSelectedValue selectValue(CallbackSelectedValue value) => value;

@NAPI(classPolicy: ClassPolicy.value)
class CallbackProjection {
  final int value;
  CallbackProjection._(this.value);
}

typedef CallbackContainers<T> = ({
  Map<String, List<CallbackValue?>> values,
  Dictionary<T?> payloads,
  List<CallbackBox?> references,
  CallbackResource? resource,
});

@NAPI()
CallbackContainers<T> callContainers<T>(
  CallbackContainers<T> Function(CallbackContainers<T>) callback,
  CallbackContainers<T> value,
) => callback(value);

@NAPI()
Future<CallbackContainers<T>> callAsyncContainers<T>(
  Future<CallbackContainers<T>> Function(CallbackContainers<T>) callback,
  CallbackContainers<T> value,
) => callback(value);

@NAPI()
Map<CallbackValue, int> callKeyMap(
  Map<CallbackValue, int> Function(Map<CallbackValue, int>) callback,
) => callback({CallbackValue(1): 2});

@NAPI()
CallbackNormalized callNormalized(
  CallbackNormalized Function(CallbackNormalized) callback,
  String value,
) => callback(CallbackNormalized.parse(value));

@NAPI()
int callProjection(int Function(CallbackProjection) callback) =>
    callback(CallbackProjection._(42));

@NAPI()
int readProjectionCallback(JsArray<CallbackProjection?> Function() callback) =>
    callback().get(0)?.value ?? -1;

@NAPI()
CallbackBox? callReference(
  CallbackBox? Function(CallbackBox?) callback,
  CallbackBox? value,
) => callback(value);

@NAPI()
int callNewResource(
  CallbackResource Function(CallbackResource) callback,
  int id,
) => callback(CallbackResource(id)).id;

@NAPI()
Future<int> callAsyncNewResource(
  Future<CallbackResource> Function(CallbackResource) callback,
  int id,
) async => (await callback(CallbackResource(id))).id;

@NAPI()
void startResourceCallback(
  Future<void> Function(CallbackResource) callback,
  int id,
) {
  callback(CallbackResource(id));
}

@NAPI()
T callPayload<T>(T Function(T) callback, T value) => callback(value);

@NAPI()
Future<T> callAsyncPayload<T>(Future<T> Function(T) callback, T value) =>
    callback(value);

@NAPI()
class CallbackPayloadBox<T> {
  T? _saved;
  T Function(T)? _callback;
  CallbackPayloadBox();
  T remember(T Function(T) callback, T value) {
    _callback = callback;
    final result = callback(value);
    _saved = result;
    return result;
  }

  T saved() => _saved as T;
  T invoke(T value) => _callback!(value);
  void clear() {
    _saved = null;
    _callback = null;
  }
}

@NAPI()
void rejectCallbackPayload<T>((T, CallbackValue) Function() callback) =>
    callback();

@NAPI()
List<int> callOptionalPositionals(int Function([int]) callback) => [
  callback(),
  callback(3),
];

@NAPI()
List<int?> callNullablePositionals(int? Function([int?]) callback) => [
  callback(),
  callback(null),
  callback(4),
];

@NAPI()
List<T?> callOpaquePositionals<T>(T? Function([T?]) callback, T value) => [
  callback(),
  callback(null),
  callback(value),
];

@NAPI()
List<int> callOptionalNames(
  int Function({
    int callback,
    int operation,
    int arguments,
    int value,
    int env,
    int adapter,
    int state,
  })
  callback,
) => [
  callback(),
  callback(callback: 1),
  callback(operation: 2, arguments: 3, value: 4, env: 5, adapter: 6, state: 7),
];

@NAPI()
List<int> callNamesBA(int Function({int b, int a}) callback) => [
  callback(b: 2, a: 1),
  callback(b: 3),
  callback(),
];

@NAPI()
List<int> callNamesAB(int Function({int a, int b}) callback) => [
  callback(a: 1, b: 2),
  callback(b: 3),
  callback(),
];

@NAPI()
List<int> callMixedNames(
  int Function(
    int value, {
    required int operation,
    required int constructor,
    int callback,
  })
  callback,
) => [
  callback(1, operation: 2, constructor: 4),
  callback(1, operation: 2, constructor: 4, callback: 3),
];

@NAPI()
int callRequiredNames(int Function({required int constructor}) callback) =>
    callback(constructor: 6);

@NAPI()
Future<List<int>> callAsyncOptionalPositionals(
  Future<int> Function([int]) callback,
) async => [await callback(), await callback(5)];

@NAPI()
Future<List<T?>> callAsyncOptionalNames<T>(
  Future<T?> Function({T? value}) callback,
  T value,
) async => [
  await callback(),
  await callback(value: null),
  await callback(value: value),
];

@NAPI()
List<int> callOptionalModels(
  int Function({CallbackResource? resource, CallbackValue? value}) callback,
  int id,
) => [
  callback(),
  callback(resource: null, value: null),
  callback(value: CallbackValue(1)),
  callback(resource: CallbackResource(id)),
];

@NAPI()
bool callbackParameterPolicies(
  int Function([int value]) optional,
  int Function([int renamed]) renamed,
  int Function(int value) mandatory,
  int Function({int value}) named,
  int Function({int other}) other,
) =>
    identical(optional, renamed) &&
    !identical(optional, mandatory) &&
    !identical(optional, named) &&
    !identical(named, other);
