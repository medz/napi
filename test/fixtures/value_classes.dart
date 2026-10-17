import 'package:napi/napi.dart';

import 'classes.dart';
export 'dictionaries.dart';
export 'reference_hierarchy.dart';
export 'reference_views.dart';

int _constructions = 0;
int _calls = 0;
int _hashes = 0;
final _trace = <String>[];

@NAPI()
int valueConstructions() => _constructions;
@NAPI()
int valueCalls() => _calls;
@NAPI()
int valueHashes() => _hashes;
@NAPI()
String valueTrace() => _trace.join(',');

@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new')
class ValuePoint {
  final int x;
  final int y;
  final int? tag;
  ValuePoint(this.x, {this.y = 7, this.tag}) {
    _constructions++;
    if (x < 0) throw StateError('negative point');
  }
}

@NAPI()
ValuePoint echoValuePoint(ValuePoint value) {
  _calls++;
  return value;
}

@NAPI()
ValuePoint? nullableValuePoint(ValuePoint? value) => value;
@NAPI()
List<ValuePoint> echoValuePoints(List<ValuePoint> value) => value;
@NAPI()
List<ValuePoint> repeatedValuePoint(ValuePoint value) => [value, value];
@NAPI()
List<(ValuePoint, int)> valueRows(List<(ValuePoint, int)> value) => value;

@NAPI(
  classPolicy: ClassPolicy.value,
  valueConstructor: 'checked',
  valueFields: {'source': 'value'},
)
class ValueNormalized {
  @NAPI(name: 'total')
  final int value;
  ValueNormalized.checked(String source) : value = _parse(source);
  static int _parse(String source) {
    _constructions++;
    return int.parse(source);
  }

  int get doubled => value * 2;
  int total() =>
      value; // Same wire name as the field; methods are not value data.
}

@NAPI()
ValueNormalized normalizeValue(ValueNormalized value) => value;

@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new')
class ValueNode {
  final int value;
  ValueNode? next;
  ValueNode(this.value, {this.next}) {
    _constructions++;
  }
}

@NAPI()
ValueNode echoValueNode(ValueNode value) => value;
@NAPI(bigint: true)
ValueNode bigintValueNode(ValueNode value) => value;
@NAPI()
ValueNode cyclicValueNode() {
  final value = ValueNode(1);
  value.next = value;
  return value;
}

@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new')
class ValueBranch {
  final int label;
  final ValueLink? link;
  ValueBranch(this.label, {this.link});
}

@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new')
class ValueLink {
  final String text;
  final ValueBranch? branch;
  ValueLink(this.text, {this.branch});
}

@NAPI()
ValueBranch echoValueBranch(ValueBranch value) => value;

@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new')
abstract class ValueLeft {
  factory ValueLeft(int left) = _ValuePair.left;
  int get left;
}

@NAPI(classPolicy: ClassPolicy.value)
abstract class ValueRight {
  int get right;
}

class _ValuePair implements ValueLeft, ValueRight {
  @override
  final int left;
  @override
  final int right;
  _ValuePair.left(this.left) : right = left + 10 {
    _constructions++;
  }
}

@NAPI()
ValueLeft echoValueLeft(ValueLeft value) => value;
@NAPI()
(ValueLeft, ValueRight) valueInterfaces(int value) {
  final pair = _ValuePair.left(value);
  return (pair, pair);
}

@NAPI(classPolicy: ClassPolicy.value)
class ValueLeaf {
  int _value = 1;
  @NAPI(name: 'value')
  int get rawValue {
    _trace.add('leaf');
    return _value;
  }

  set rawValue(int next) => _value = next;
}

@NAPI(classPolicy: ClassPolicy.value)
class ValueSnapshot {
  final ValueLeaf _leaf = ValueLeaf();
  ValueLeaf get first {
    _trace.add('first');
    return _leaf;
  }

  int get later {
    _trace.add('later');
    _leaf._value = 9;
    return 9;
  }

  ValueLeaf get repeated {
    _trace.add('repeated');
    return _leaf;
  }
}

@NAPI()
ValueSnapshot valueSnapshot() {
  _trace.clear();
  return ValueSnapshot();
}

@NAPI(classPolicy: ClassPolicy.value)
class ValueGetterFailure {
  ValueLeaf get first {
    _trace.add('first');
    return ValueLeaf();
  }

  int get broken {
    _trace.add('broken');
    throw StateError('value getter failed');
  }

  int get never {
    _trace.add('never');
    return 0;
  }
}

@NAPI()
ValueGetterFailure failingValueGetter() {
  _trace.clear();
  return ValueGetterFailure();
}

@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new')
class ValueKey {
  final int id;
  ValueKey(this.id) {
    _constructions++;
  }
  @NAPI(exclude: true)
  @override
  int get hashCode {
    _hashes++;
    return id;
  }

  @NAPI(exclude: true)
  @override
  bool operator ==(Object other) => other is ValueKey && other.id == id;
}

@NAPI()
Map<ValueKey, int> valueKeyMap(Map<ValueKey, int> value) => value;

@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new')
class ValueEnvelope {
  final List<ValuePoint?> points;
  final Map<String, ValueNode?> nodes;
  final Dictionary<ValuePoint> names;
  final (ValuePoint, {RefBox? owner}) row;
  final RefBox? owner;
  ValueEnvelope(this.points, this.nodes, this.names, this.row, this.owner) {
    _constructions++;
  }
}

@NAPI()
ValueEnvelope echoValueEnvelope(ValueEnvelope value) => value;

@NAPI(classPolicy: ClassPolicy.value)
class ValueFailure {
  final RefBase owner;
  final int number;
  ValueFailure(this.owner, this.number);
}

RefChild? _partial;
@NAPI()
ValueFailure failingValueReference() =>
    ValueFailure(_partial = RefChild(), 9007199254740992);
@NAPI()
RefChild valueReferenceChild() => _partial!;
@NAPI()
ValueFailure failingExistingValueReference(RefBase owner) =>
    ValueFailure(owner, 9007199254740992);

@NAPI()
int valueThenScalar(ValuePoint first, int second) {
  _calls++;
  return first.x + second;
}

@NAPI()
int valueThenReference(ValuePoint first, RefBox second) {
  _calls++;
  return first.x + second.value;
}

@NAPI()
class ValueReceiver {
  ValueReceiver();
  factory ValueReceiver.checked(ValuePoint first, {required int amount}) {
    _calls++;
    return ValueReceiver();
  }
  int pair(ValuePoint first, int second) {
    _calls++;
    return first.x + second;
  }

  int named(ValuePoint first, {required int amount}) {
    _calls++;
    return first.x + amount;
  }
}

@NAPI(classPolicy: ClassPolicy.value)
class ValueScalarOrder {
  final int bad = 9007199254740992;
  final ValueGetterFailure later = ValueGetterFailure();
}

@NAPI()
ValueScalarOrder failingValueScalarOrder() {
  _trace.clear();
  return ValueScalarOrder();
}

@NAPI(classPolicy: ClassPolicy.value)
class ValueReferenceOrder {
  final RefBase bad;
  final ValueGetterFailure later = ValueGetterFailure();
  ValueReferenceOrder(this.bad);
}

final _orderedReference = RefChild();
@NAPI()
RefChild valueOrderReference() => _orderedReference;
@NAPI()
ValueReferenceOrder failingValueBrandOrder() {
  _trace.clear();
  return ValueReferenceOrder(_orderedReference);
}
