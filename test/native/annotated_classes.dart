import 'package:napi/napi.dart';

@NAPI()
class Counter {
  Counter([this.value = 0]) {
    created++;
  }

  Counter.named({this.value = 5, this.note}) {
    created++;
  }

  int value;
  String? note;
  Counter? peer;
  final String kind = 'counter';

  static int created = 0;
  static int _limit = 100;
  static int get limit => _limit;
  static set limit(int value) {
    if (value < 0) throw RangeError('Counter limit must be non-negative');
    _limit = value;
  }

  static Counter zero() {
    final counter = Counter(1);
    counter._reset();
    return counter;
  }

  int get doubled => value * 2;
  set doubled(int next) => value = next ~/ 2;

  int increment([int step = 1]) => value += step;
  String namedStep({int step = 1, String note = 'base'}) => '$step|$note';
  Counter same() => this;

  @NAPI(name: 'reset')
  void _reset([int next = 0]) {
    value = next;
  }
}

@NAPI()
class Other {}

@NAPI()
abstract class FactoryCounter {
  factory FactoryCounter([int value]) = _FactoryCounter;

  int get value;
}

class _FactoryCounter implements FactoryCounter {
  _FactoryCounter([this.value = 3]);

  @override
  final int value;
}

@NAPI()
class NamedOnly {
  NamedOnly.create([this.value = 4]);

  final int value;
}

class _Derived extends Counter {
  @override
  int increment([int step = 2]) => super.increment(step);

  @override
  String namedStep({int step = 3, String note = 'derived'}) => '$step|$note';
}

class _Multi extends Counter implements Other {}

final _shared = Counter(8);
final _multi = _Multi();

@NAPI()
Counter echoCounter(Counter value) => value;

@NAPI()
Counter? echoNullableCounter([Counter? value]) => value;

@NAPI()
Counter derived() => _Derived();

@NAPI()
Counter sharedCounter() => _shared;

@NAPI()
Counter multiCounter() => _multi;

@NAPI()
Other multiOther() => _multi;
