import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:napi/napi.dart';

@napi
Future<bool> asyncBool(bool value) async {
  await Future<void>.value();
  return value;
}

@napi
Future<int> asyncInt(int value) async {
  await Future<void>.value();
  return value;
}

@napi
Future<double> asyncDouble(double value) async {
  await Future<void>.value();
  return value;
}

@napi
Future<String> asyncString(String value) async {
  await Future<void>.value();
  return value;
}

@napi
Future<Uint8List> asyncBytes(Uint8List value) async {
  await Future<void>.delayed(Duration.zero);
  return value;
}

@napi
Future<bool?> nullableBool(bool? value) async => value;

@napi
Future<int?> nullableInt(int? value) async => value;

@napi
Future<double?> nullableDouble(double? value) async => value;

@napi
Future<String?> nullableString(String? value) async => value;

@napi
Future<Uint8List?> nullableBytes(Uint8List? value) async {
  await Future<void>.delayed(Duration.zero);
  return value;
}

@napi
Future<void> asyncVoid() async {
  await Future<void>.value();
}

@napi
Future<int> throwBeforeFuture(String message) => throw StateError(message);

@napi
Future<int> asyncFailure(int kind) async {
  await Future<void>.value();
  switch (kind) {
    case 0:
      throw ArgumentError('argument failure');
    case 1:
      throw RangeError('range failure');
    default:
      throw StateError('state failure');
  }
}

@napi
Future<int> oversizedResult() async => 9007199254740992;

@napi
Future<int?> nullableOversizedResult() async => 9007199254740992;

@napi
Future<int> completerSync(int value) {
  final completer = Completer<int>.sync();
  completer.complete(value);
  return completer.future;
}

@napi
Future<String> microtaskOrder() async {
  final events = <String>['before'];
  scheduleMicrotask(() => events.add('scheduled'));
  await Future<void>.value();
  events.add('after');
  return events.join(',');
}

@napi
Future<int> delayedValue(int value) async {
  await Future<void>.delayed(const Duration(milliseconds: 1));
  return value;
}

@napi
Future<int> canceledTimer() async {
  var calls = 0;
  final timer = Timer(const Duration(milliseconds: 1), () => calls++);
  timer.cancel();
  await Future<void>.delayed(const Duration(milliseconds: 4));
  return calls;
}

Uint8List _retainedBytes = Uint8List(0);

@napi
Future<void> retainBytes(Uint8List value) async {
  _retainedBytes = value;
  await Future<void>.value();
}

@napi
Future<Uint8List> readRetainedBytes() async => _retainedBytes;

@napi
Future<Uint8List> freshBytes() async => Uint8List.fromList([0, 128, 255]);

@JS('napiAsyncHook')
external JSPromise<JSAny?> _napiAsyncHook();

@napi
Future<void> javascriptFailure() async {
  await _napiAsyncHook().toDart;
}

final class _BadError implements Exception {
  @override
  String toString() => throw StateError('error formatter failed');
}

final class _BadStack implements StackTrace {
  @override
  String toString() => throw StateError('stack formatter failed');
}

@napi
Future<int> badErrorFormatter() => Future<int>.error(_BadError());

@napi
Future<int> badStackFormatter() =>
    Future<int>.error(StateError('original failure'), _BadStack());

@napi
int syncBadErrorFormatter() => throw _BadError();
