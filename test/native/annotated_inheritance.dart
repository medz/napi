import 'package:napi/napi.dart';

@NAPI()
class Leaf extends _Middle with Extra {
  @NAPI()
  Leaf([super.value = 3]);
}

mixin Extra {
  @NAPI()
  int extra() => 31;
}

class _Middle extends Derived {
  _Middle([super.value = 2]);

  @override
  int sum([int step = 7]) => super.sum(step);
}

@NAPI()
class Derived extends Base {
  @NAPI()
  Derived([super.value = 2]);

  @NAPI()
  factory Derived.shared() => _shared;

  @override
  int sum([int step = 5]) => super.sum(step) * 2;

  @override
  String describe({int times = 2, String label = 'derived'}) =>
      super.describe(times: times, label: label);

  @override
  @NAPI()
  int get level => value + 100;

  @override
  @NAPI()
  set stored(int next) => super.stored = next * 2;

  @override
  @NAPI(name: 'readDerived')
  int aliased() => value * 3;

  @NAPI()
  String onlyDerived() => 'derived';
}

@NAPI()
class Base {
  @NAPI()
  Base([this.value = 1]) {
    created++;
  }

  @NAPI()
  factory Base.shared() => _shared;

  @NAPI()
  static int created = 0;

  @NAPI()
  int value;

  @NAPI()
  int sum([int step = 1]) => value + step;

  @NAPI()
  String describe({int times = 1, String label = 'base'}) =>
      '$label:${value * times}';

  @NAPI()
  int get level => value;
  @NAPI()
  set level(int next) => value = next;

  @NAPI()
  int get stored => value;
  @NAPI()
  set stored(int next) => value = next;

  @NAPI(name: 'readAlias')
  int aliased() => value;

  @NAPI()
  Base same() => this;
}

final _shared = Derived(11);

@NAPI()
Base echoBase(Base value) => value;

@NAPI()
Derived echoDerived(Derived value) => value;

@NAPI()
Base sharedBase() => _shared;

@NAPI()
class GenericBase<T> {
  @NAPI()
  GenericBase();

  @NAPI()
  List<T> copy(List<T> values) => values;
}

@NAPI()
class NumDerived extends GenericBase<num> {
  @NAPI()
  NumDerived();
}

@NAPI()
class NumericParent<T extends num> {
  @NAPI()
  NumericParent();

  Object? _last;

  @NAPI()
  void accept(T value) => _last = value;

  @NAPI()
  Object? get last => _last;
}

@NAPI()
class WideChild extends NumericParent<num> {
  @NAPI()
  WideChild();

  @override
  @NAPI()
  void accept(Object value) => _last = value;
}
