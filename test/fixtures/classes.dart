import 'dart:collection';

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

int _referenceConstructions = 0;
RefBox? _heldReference;
WeakReference<RefBox>? _lastReference;
List<int> _pressure = [];

@NAPI()
int referenceConstructions() => _referenceConstructions;
@NAPI()
RefBox identityReference(RefBox value) => value;
@NAPI()
RefBox? nullableReference(RefBox? value) => value;
@NAPI()
RefBox? optionalReference([RefBox? value]) => value;
@NAPI()
RefBox? namedReference({required RefBox? value}) => value;
@NAPI()
int holdReference(RefBox? value) {
  _heldReference = value;
  return 0;
}

@NAPI()
RefBox? heldReference() => _heldReference;
@NAPI()
bool referenceAlive() => _lastReference?.target != null;
@NAPI()
int referencePressure(int seed) {
  _pressure = List<int>.generate(65536, (i) => i + seed);
  return _pressure[seed & 65535];
}

@NAPI()
class RefBox {
  int value;
  RefBox? peer;
  RefBox([this.value = 0]) {
    _referenceConstructions++;
    _lastReference = WeakReference(this);
  }
  @NAPI(name: 'from')
  RefBox.named(this.value) {
    _referenceConstructions++;
    _lastReference = WeakReference(this);
  }
  factory RefBox.shared() => _sharedReference;
  RefBox self() => this;
  RefBox choose(RefBox other) => other;
  RefBox? optional([RefBox? other]) => other;
  static RefBox echo(RefBox value) => value;
}

final _sharedReference = RefBox(42);

@NAPI()
class Once {
  factory Once() => _once;
  Once._();
  Once self() => this;
}

final _once = Once._();

@NAPI()
class NamedReference {
  NamedReference.make(this.box);
  final RefBox box;
}

@NAPI()
RefBase identityBase(RefBase value) => value;

@NAPI()
class RefBase {
  RefBase();
}

@NAPI()
class RefChild extends RefBase {
  RefChild();
  RefBase asBase() => this;
}

int _structuralReferenceCalls = 0;
List<(RefBox, {List<RefBox?>? peers})?>? _heldReferenceRows;

@NAPI()
int structuralReferenceCalls() => _structuralReferenceCalls;
@NAPI()
List<(RefBox, {List<RefBox?>? peers})?> echoReferenceRows(
  List<(RefBox, {List<RefBox?>? peers})?> value,
) {
  _structuralReferenceCalls++;
  return value;
}

@NAPI()
int holdReferenceRows(List<(RefBox, {List<RefBox?>? peers})?>? value) {
  _heldReferenceRows = value;
  return 0;
}

@NAPI()
List<(RefBox, {List<RefBox?>? peers})?>? heldReferenceRows() =>
    _heldReferenceRows;
@NAPI()
(RefBox, int) invalidReferenceRow(RefBox value) => (value, 9007199254740992);
@NAPI()
List<RefBox?> mixedReferenceRows(RefBox first, List<RefBox?> rest) => [
  first,
  ...rest,
];

@NAPI()
class RefCollection {
  List<RefBox?> values;
  final List<int?>? counts;
  (RefBox, {List<RefBox?> peers})? _row;
  RefCollection(this.values, {this.counts});
  factory RefCollection.fromRows(List<RefBox?> values) => RefCollection(values);
  // Exercise explicit structural accessor pairs separately from public fields.
  // ignore: unnecessary_getters_setters
  (RefBox, {List<RefBox?> peers})? get row => _row;
  set row((RefBox, {List<RefBox?> peers})? value) => _row = value;
  List<RefBox?> replace(List<RefBox?> value) => values = value;
  List<int?>? optional([List<int?>? value]) => value;
  List<RefBox?> named({required List<RefBox?> value}) => value;
  @NAPI(name: 'duplicate')
  static List<RefBox?> echo(List<RefBox?> value) => value;
}

RefChild? _partialReference;
@NAPI()
List<RefBase> failingReferenceList() =>
    _PartialReferenceList(_partialReference = RefChild());
@NAPI()
(RefBase, int) failingReferenceScalar() =>
    (_partialReference = RefChild(), 9007199254740992);
@NAPI()
RefChild partialReferenceChild() => _partialReference!;
@NAPI()
RefBase createPartialReferenceBase() => _partialReference = RefChild();
@NAPI()
(RefBase, int) failingExistingReferenceScalar(RefBase value) =>
    (value, 9007199254740992);

class _PartialReferenceList extends ListBase<RefBase> {
  final RefBase firstValue;
  _PartialReferenceList(this.firstValue);
  @override
  int get length => 2;
  @override
  set length(int value) => throw UnsupportedError('fixed length');
  @override
  RefBase operator [](int index) =>
      index == 0 ? firstValue : throw StateError('later output read failed');
  @override
  void operator []=(int index, RefBase value) =>
      throw UnsupportedError('readonly');
}
