import 'package:napi/napi.dart' as napi;

// A typedef is intentionally present: its Dart int policy must stay safe-int.
typedef Count = int;

int _calls = 0;
@napi.NAPI()
Count add(Count a, Count b) {
  _calls++;
  return a + b;
}

@napi.NAPI()
int calls() => _calls;
@napi.NAPI()
int echo(int value) => value;
// Strict-mode JavaScript binding restrictions do not apply to Dart names.
@napi.NAPI(name: 'evaluate')
int eval(int arguments) => arguments + 1;
@napi.NAPI(name: 'argumentCount')
int arguments(int eval) => eval + 2;
@napi.NAPI()
int fail(int mode) {
  if (mode == 1) throw StateError('intentional failure');
  if (mode == 2) throw _Unprintable();
  return mode;
}

class _Unprintable {
  @override
  String toString() => throw StateError('description also failed');
}

void main() => throw StateError('business main must not run');
