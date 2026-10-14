import 'package:napi/napi.dart';

import 'conditional/scalar.dart';

@NAPI()
int add(int left, int right) => left + right;

@NAPI()
int echoInt(int value) => value;

@NAPI()
double echoDouble(double value) => value;

@NAPI()
bool negate(bool value) => !value;

@NAPI()
String echoString(String value) => value;

@NAPI()
void accept(String value) {}

@NAPI()
int unsafeOutput() => 9007199254740992;

@NAPI()
String fail(String kind) {
  if (kind == 'range') throw RangeError('fixture range failure');
  if (kind == 'type') throw ArgumentError('fixture argument failure');
  throw StateError('fixture state failure');
}

// Names deliberately overlap facade internals or require Dart literal escaping.
@NAPI()
int api(int value) => value;

@NAPI()
int $echo(int value) => value;

// Error formatting is user code too; these probe the boundary's fallback.
class _BadMessage implements Exception {
  @override
  String toString() => throw StateError('message formatting failed');
}

class _BadType implements Exception {
  @override
  Type get runtimeType => throw StateError('type formatting failed');

  @override
  String toString() => 'fixture opaque exception';
}

void failBadMessage() => throw _BadMessage();
void failBadType() => throw _BadType();
void failArgumentMessage() => throw ArgumentError.value(_BadMessage(), 'value');

// The host-analysis fallback is double, but the Wasm declaration is int.
// If analysis uses the wrong profile this silently rounds instead of rejecting.
Scalar unsafeConditionalOutput() => 9007199254740992 + 1;
Scalar echoConditional(Scalar value) => value;
