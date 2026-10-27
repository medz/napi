import 'package:napi/napi.dart';

@NAPI()
class Counter {
  @NAPI()
  Counter([this.value = 0]) {
    created++;
  }

  @NAPI()
  Counter.named({this.value = 5, this.note}) {
    created++;
  }

  @NAPI()
  int value;
  @NAPI()
  String? note;
  @NAPI()
  Counter? peer;
  @NAPI()
  final String kind = 'counter';

  @NAPI()
  static int created = 0;
  static int _limit = 100;
  @NAPI()
  static int get limit => _limit;
  @NAPI()
  static set limit(int value) {
    if (value < 0) throw RangeError('Counter limit must be non-negative');
    _limit = value;
  }

  @NAPI()
  static Counter zero() {
    final counter = Counter(1);
    counter._reset();
    return counter;
  }

  @NAPI()
  int get doubled => value * 2;
  @NAPI()
  set doubled(int next) => value = next ~/ 2;

  @NAPI()
  int increment([int step = 1]) => value += step;
  @NAPI()
  String namedStep({int step = 1, String note = 'base'}) => '$step|$note';
  @NAPI()
  Counter same() => this;

  @NAPI(name: 'reset')
  void _reset([int next = 0]) {
    value = next;
  }
}

@NAPI()
class Other {
  @NAPI()
  Other();
}

@NAPI()
abstract class FactoryCounter {
  @NAPI()
  factory FactoryCounter([int value]) = _FactoryCounter;

  @NAPI()
  int get value;
}

class _FactoryCounter implements FactoryCounter {
  _FactoryCounter([this.value = 3]);

  @override
  final int value;
}

@NAPI()
class NamedOnly {
  @NAPI()
  NamedOnly.create([this.value = 4]);

  @NAPI()
  final int value;
}

@NAPI()
class Visibility {
  @NAPI()
  Visibility();

  Visibility.named();
  Visibility.hidden(Set<int> value) : unsupported = value;

  @NAPI()
  final int id = 7;
  @NAPI()
  late final int lazy = id + 4;

  int hiddenField = 1;
  int hiddenMethod() => hiddenField;
  int get hiddenAccessor => hiddenField;
  set hiddenAccessor(int value) => hiddenField = value;
  static int hiddenStaticField = 2;
  static int hiddenStaticMethod() => hiddenStaticField;
  Set<int> unsupported = {1};
  Set<int> unsupportedMethod() => unsupported;

  int _read = 3;
  int _written = 0;

  @NAPI()
  int get readOnly => _read;
  set readOnly(int value) => _read = value;

  int get writeOnly => _written;
  @NAPI()
  set writeOnly(int value) => _written = value;

  @NAPI()
  int readStored() => _written;
}

@NAPI()
class ReturnedOnly {
  ReturnedOnly(this.value);

  @NAPI()
  final int value;

  @NAPI()
  int read() => value;
}

@NAPI()
ReturnedOnly returnedOnly() => ReturnedOnly(19);

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
