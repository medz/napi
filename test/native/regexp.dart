import 'counter.dart' as counter;

@pragma('vm:entry-point')
int initialize(
  int envAddress,
  int exportsAddress,
  int callJsAddress,
  int ownerAddress,
  int finalizerAddress,
  int hasLivePortsAddress,
) {
  final letters = RegExp(r'^\p{L}+$', unicode: true);
  if (!letters.hasMatch('你好Abc') ||
      letters.hasMatch('abc123') ||
      'abcσ'.toUpperCase() != 'ABCΣ') {
    throw StateError('Unicode RegExp or case conversion failed');
  }
  return counter.initialize(
    envAddress,
    exportsAddress,
    callJsAddress,
    ownerAddress,
    finalizerAddress,
    hasLivePortsAddress,
  );
}

@pragma('vm:entry-point')
void afterPump() => counter.afterPump();

@pragma('vm:entry-point')
void dispose() => counter.dispose();

void main() {}
