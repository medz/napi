import 'dart:js_interop';
import 'dart:js_interop_unsafe';

@JS('Object.create')
external JSObject _objectCreate(JSAny? prototype);

JSObject _object(Map<String, JSAny?> fields) {
  final object = _objectCreate(null);
  for (final entry in fields.entries) {
    object.setProperty(entry.key.toJS, entry.value);
  }
  return object;
}

/// Captures conversion and user-code failures at the Dart/JavaScript boundary.
///
/// Generated JavaScript unwraps this private envelope before returning to callers.
JSObject guard(JSAny? Function() body) {
  try {
    return _object({'ok': true.toJS, 'value': body()});
  } catch (error, stack) {
    return _object({
      'ok': false.toJS,
      'error': _object({
        'kind':
            (error is RangeError
                    ? 'range'
                    : error is ArgumentError || error is TypeError
                    ? 'type'
                    : 'error')
                .toJS,
        'dartType': _describe(
          () => error.runtimeType.toString(),
          'UnknownDartError',
        ).toJS,
        'message': _describe(
          () => error.toString(),
          'Dart exception (message unavailable)',
        ).toJS,
        'dartStack': _describe(() => stack.toString(), '').toJS,
      }),
    });
  }
}

/// Converts the default Dart integer representation without silent rounding.
double checkedIntOutput(int value, String path) {
  const max = 9007199254740991;
  if (value < -max || value > max) {
    throw RangeError(
      '$path: integer is outside the JavaScript safe-number range',
    );
  }
  return value.toDouble();
}

/// Completes the synchronous, per-instance SDK-loader registration handshake.
void registerBindings(List<String> arguments, JSObject bindings) {
  if (arguments.length != 1) {
    throw StateError('Expected exactly one binding registration key');
  }
  final callback = globalContext.getProperty<JSAny?>(arguments.single.toJS);
  if (callback == null || !callback.isA<JSFunction>()) {
    throw StateError('Binding registration callback is missing');
  }
  (callback as JSFunction).callAsFunction(null, bindings);
}

// User-thrown objects can themselves throw while being formatted. Never let a
// secondary diagnostic failure replace the original boundary error envelope.
String _describe(String Function() describe, String fallback) {
  try {
    return describe();
  } catch (_) {
    return fallback;
  }
}
