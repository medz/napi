import 'package:napi/napi.dart';

final _counters = <WeakReference<Counter>>[];

@NAPI()
int liveCounters() => _counters.where((entry) => entry.target != null).length;

@NAPI()
class Counter {
  int _value;
  Counter([int value = 0]) : _value = value {
    if (value == -999) throw StateError('constructor failed');
    _counters.add(WeakReference(this));
  }
  // Exercise explicit accessor pairs independently of public fields.
  // ignore: unnecessary_getters_setters
  int get value => _value;
  set value(int value) => _value = value;
  int increment([int amount = 1]) => _value += amount;
  int named({int amount = 2}) => _value += amount;
  int requiredNamed({required int? amount}) => _value += amount ?? 0;
  void reset() => _value = 0;
  void fail() => throw StateError('method failed');
  void badDescription() => throw _BadDescription();
  static String label() => 'Dart Counter';
  static int count = 0;
  @NAPI(name: 'doubleValue')
  int twice() => _value * 2;
  @NAPI(exclude: true)
  String hidden() => 'hidden';
}

@NAPI()
class Other {
  final int value;
  Other([this.value = 4]);
}

@NAPI()
class Scalars {
  bool enabled = true;
  String text = '';
  double number = 0;
  BigInt integer = BigInt.zero;
  int? nullable;
  Scalars();
  String echo(String value) => value;
  int safe(int value) => value;
  BigInt arbitrary(BigInt value) => value;
  void get empty {}
  @NAPI(name: 'constructor')
  static int buildTag() => 42;
}

@NAPI()
class Options {
  final String label;
  final int? amount;
  Options({this.label = 'default', required this.amount});
}

class _BadDescription {
  @override
  String toString() => throw StateError('description failed');
}
