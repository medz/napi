// A typedef is intentionally present: its Dart int policy must stay safe-int.
typedef Count = int;

int _calls = 0;
Count add(Count a, Count b) {
  _calls++;
  return a + b;
}

int calls() => _calls;
int echo(int value) => value;
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
