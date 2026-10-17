import 'package:napi/napi.dart';

int _constructions = 0;
HierarchyChild? _held;

@NAPI()
int hierarchyConstructions() => _constructions;

@NAPI()
class HierarchyBase {
  int _value;
  HierarchyBase([this._value = 0]) {
    _constructions++;
  }
  factory HierarchyBase.child([int value = 0]) => HierarchyChild(value);
  // Exercise separately declared getter/setter inheritance.
  // ignore: unnecessary_getters_setters
  int get value => _value;
  set value(int value) => _value = value;
  int defaults([int first = 1, int second = 2]) => first * 100 + second;
  int named({int amount = 3}) => amount;
  void run() {}
  HierarchyBase self() => this;
  static String baseOnly() => 'base';
}

class _HierarchyMiddle extends HierarchyBase {
  _HierarchyMiddle(super.value);
  @override
  int named({int amount = 5}) => amount;
}

@NAPI()
abstract class HierarchyView {
  HierarchyView._();
  int view();
}

@NAPI()
class HierarchyChild extends _HierarchyMiddle implements HierarchyView {
  // Keep the selected declaration's default explicit.
  // ignore: use_super_parameters
  HierarchyChild([int value = 0]) : super(value);
  @override
  int defaults([int first = 7, int second = 8]) => first * 100 + second;
  @override
  int view() => value;
  @override
  int run() => 42;
  static String childOnly() => 'child';
}

@NAPI()
class HierarchyGetter extends HierarchyChild {
  HierarchyGetter([super.value]);
  @override
  int get value => super.value * 2;
}

@NAPI()
class HierarchySetter extends HierarchyChild {
  HierarchySetter([super.value]);
  @override
  set value(int value) => super.value = value + 1;
}

@NAPI()
class HierarchyReadonly {
  int _value = 1;
  HierarchyReadonly();
  int get value => _value;
}

@NAPI()
class HierarchyWritable extends HierarchyReadonly {
  HierarchyWritable();
  set value(int value) => _value = value;
}

@NAPI()
class HierarchyFactory {
  factory HierarchyFactory() => _factory ??= HierarchyFactoryChild();
  HierarchyFactory._();
  HierarchyFactory self() => this;
}

@NAPI()
class HierarchyFactoryChild extends HierarchyFactory {
  HierarchyFactoryChild() : super._();
  int child() => 42;
}

HierarchyFactoryChild? _factory;
@NAPI()
int resetHierarchyFactory() {
  _factory = null;
  return 0;
}

@NAPI()
HierarchyBase makeHierarchyBase(int value) => _held = HierarchyChild(value);
@NAPI()
HierarchyChild makeHierarchyChild(int value) => _held = HierarchyChild(value);
@NAPI()
HierarchyBase? heldHierarchyBase() => _held;
@NAPI()
HierarchyChild? heldHierarchyChild() => _held;
@NAPI()
int clearHierarchy() {
  _held = null;
  return 0;
}

@NAPI()
HierarchyBase echoHierarchyBase(HierarchyBase value) => value;
@NAPI()
HierarchyChild echoHierarchyChild(HierarchyChild value) => value;
@NAPI()
HierarchyView echoHierarchyView(HierarchyView value) => value;
@NAPI()
(HierarchyBase, HierarchyChild, HierarchyView) hierarchyViews(
  HierarchyChild value,
) => (value, value, value);
@NAPI()
List<HierarchyBase> hierarchyList(List<HierarchyBase> values) => values;

@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new')
class HierarchyEnvelope {
  final HierarchyBase base;
  final HierarchyView view;
  HierarchyEnvelope(this.base, this.view);
}

@NAPI()
HierarchyEnvelope hierarchyEnvelope(HierarchyEnvelope value) => value;
@NAPI()
(HierarchyBase, int) failingHierarchy() =>
    (_held = HierarchyChild(17), 9007199254740992);

@NAPI()
class HierarchyLeft {
  HierarchyLeft();
  int left() => 1;
}

@NAPI()
class HierarchyRight {
  HierarchyRight();
  int right() => 2;
}

class _HierarchyAmbiguous implements HierarchyLeft, HierarchyRight {
  @override
  int left() => 1;
  @override
  int right() => 2;
}

final _ambiguous = _HierarchyAmbiguous();
@NAPI()
HierarchyLeft ambiguousHierarchyLeft() => _ambiguous;
@NAPI()
HierarchyRight ambiguousHierarchyRight() => _ambiguous;
