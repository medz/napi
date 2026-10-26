import 'dart:async';
import 'dart:typed_data';

import 'package:napi/napi.dart';

typedef IntCallback = int Function(int value);
typedef PositionalCallback = int Function(int value, [int step, int? maybe]);
typedef NamedCallback = String Function(int value, {int step, String? note});
typedef RequiredNamedCallback = int Function({required int value, int step});

@NAPI()
int apply(int value, IntCallback callback) => callback(value);

@NAPI()
IntCallback multiply(int factor) =>
    (value) => value * factor;

IntCallback _adder(int amount) =>
    (value) => value + amount;

final IntCallback _shared = _adder(7);

@NAPI()
IntCallback sharedCallback() => _shared;

int Function([int]) _optionalValue(int bias) =>
    ([int value = 1]) => value + bias;

final _optionalFirst = _optionalValue(0);
final _optionalReverse = _optionalValue(1);

@NAPI()
int Function() zeroView() => _optionalFirst;

@NAPI()
int Function([int]) optionalView() => _optionalFirst;

@NAPI()
int Function() reverseZeroView() => _optionalReverse;

@NAPI()
int Function([int]) reverseOptionalView() => _optionalReverse;

@NAPI()
IntCallback echoCallback(IntCallback callback) => callback;

@NAPI()
IntCallback? nullableCallback([IntCallback? callback]) => callback;

IntCallback? _saved;

@NAPI()
void saveCallback(IntCallback callback) => _saved = callback;

@NAPI()
IntCallback? savedCallback() => _saved;

@NAPI()
int callSaved(int value) => _saved!(value);

@NAPI()
void clearCallback() => _saved = null;

@NAPI()
IntCallback decorate(IntCallback callback, int factor) =>
    (value) => callback(value) * factor;

int _addOne(int value) => value + 1;

@NAPI()
int withDefault(int value, [IntCallback callback = _addOne]) => callback(value);

@NAPI()
double applyDouble(double value, double Function(double) callback) =>
    callback(value);

@NAPI()
void notify(String value, void Function(String) callback) => callback(value);

var _remembered = 0;

@NAPI()
void Function(int) numberRecorder() => (value) {
  _remembered = value;
};

@NAPI()
int rememberedNumber() => _remembered;

int? _delayed;

@NAPI()
void scheduleCallback(int value, IntCallback callback) {
  _delayed = null;
  Timer.run(() => _delayed = callback(value));
}

@NAPI()
int? delayedResult() => _delayed;

@NAPI()
String applyText(String value, String Function(String) callback) =>
    callback(value);

@NAPI()
String Function(String) textEcho() =>
    (value) => value;

@NAPI()
BigInt applyBigInt(BigInt value, BigInt Function(BigInt) callback) =>
    callback(value);

@NAPI()
BigInt Function(BigInt) bigintEcho() =>
    (value) => value;

@NAPI()
PositionalCallback positionalCallback() =>
    (int value, [int step = 9, int? maybe = 11]) => value + step + (maybe ?? 0);

@NAPI()
List<int> invokePositional(PositionalCallback callback) => [
  callback(1),
  callback(1, 2),
  callback(1, 2, null),
];

@NAPI()
NamedCallback namedCallback() =>
    (int value, {int step = 9, String? note = 'actual'}) =>
        '$value|$step|$note';

@NAPI()
List<String> invokeNamed(NamedCallback callback) => [
  callback(1),
  callback(1, step: 2),
  callback(1, note: null),
  callback(1, step: 2, note: 'explicit'),
];

@NAPI()
RequiredNamedCallback requiredNamedCallback() =>
    ({required int value, int step = 4}) => value + step;

@NAPI()
int invokeRequiredNamed(RequiredNamedCallback callback) => callback(value: 3);

@NAPI()
class Box {
  Box(this.value);
  int value;
}

@NAPI()
Box? Function(bool) boxSelector(Box value) =>
    (include) => include ? value : null;

@NAPI()
List<Map<String, Box?>> Function() nestedBoxes(Box value) =>
    () => [
      {'item': value, 'empty': null},
    ];

@NAPI()
class Calculator {
  Calculator(int factor) : operation = ((value) => value * factor);

  IntCallback operation;

  int apply(int value, IntCallback callback) => operation(callback(value));
}

@NAPI()
List<IntCallback> echoCallbacks(List<IntCallback> callbacks) => callbacks;

@NAPI()
Map<String, IntCallback> callbackMap(Map<String, IntCallback> callbacks) =>
    callbacks;

final _payloads = <int, WeakReference<_Payload>>{};

class _Payload {
  _Payload(int size) : bytes = Uint8List(size);
  final Uint8List bytes;

  int read(int index) => bytes[index];
}

@NAPI()
IntCallback payloadReader(int size) {
  final payload = _payloads[size]?.target ?? _Payload(size);
  _payloads[size] = WeakReference(payload);
  return payload.read;
}

@NAPI()
bool hasCachedPayload(int size) => _payloads[size]?.target != null;
