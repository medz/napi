import 'dart:async';
import 'dart:typed_data';

import 'package:napi/napi.dart';

import 'concrete_callables.dart' as callables;

export 'concrete_callables.dart';

part 'concrete_callable_part.dart';

class Cell<T> {
  T value;
  Cell(this.value);
  Cell.named(this.value);

  bool get isInt => T == int;
  bool get isDouble => T == double;
  T replace(T next) {
    final previous = value;
    value = next;
    return previous;
  }

  T? optional([T? next]) => next;
  T? namedOptional({T? next}) => next;
  Cell<T> self() => this;
  int count([int value = 7]) => value;
  List<Map<String, T?>> nested() => [
    {'value': value, 'empty': null},
  ];
  Future<T> futureValue() => Future.value(value);
  Stream<T> values() async* {
    yield value;
  }
}

@NAPI()
typedef IntCell = Cell<int>;

@NAPI()
typedef DoubleCell = Cell<double>;

@NAPI()
typedef NullableCell = Cell<int?>;

@NAPI()
typedef BatchCell = Cell<List<Map<String, int?>>>;

@NAPI()
class Leaf {
  int value;
  Leaf(this.value);
}

@NAPI()
typedef LeafCell = Cell<Leaf>;

typedef EquivalentInt = Cell<int>;

class Numeric<T extends num> {
  T value;
  Numeric(this.value);
  bool get isInt => T == int;
}

@NAPI()
typedef IntNumeric = Numeric<int>;

@NAPI()
IntCell echoInt(Cell<int> value) => value;

@NAPI()
DoubleCell echoDouble(Cell<double> value) => value;

@NAPI()
EquivalentInt equivalent(EquivalentInt value) => value;

@NAPI()
List<IntCell?> listCells(List<IntCell?> values) => values;

@NAPI()
Map<IntCell, DoubleCell> mapCells(Map<IntCell, DoubleCell> values) => values;

@NAPI()
({IntCell first, DoubleCell second}) pair(
  ({IntCell first, DoubleCell second}) value,
) => value;

@NAPI()
IntCell createInt(int value) => Cell<int>(value);

@NAPI()
Future<IntCell> delayedInt(IntCell value) async {
  await Future<void>.delayed(const Duration(milliseconds: 5));
  return value;
}

IntCell? _saved;
@NAPI()
int saveInt(IntCell? value) {
  _saved = value;
  return 0;
}

@NAPI()
IntCell? savedInt() => _saved;

@NAPI()
int pressure() => List.generate(2048, (index) => List.filled(32, index)).length;

class DerivedInt extends Cell<int> {
  DerivedInt(super.value);
  @override
  Type get runtimeType => throw StateError('classification read runtimeType');
}

class Bottom implements Cell<Never> {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('classification called business code');
}

@NAPI()
IntCell createDerived(int value) => DerivedInt(value);

@NAPI()
NullableCell widenedInt() => Cell<int>(1);

@NAPI()
IntCell ambiguousInt() => Bottom();

class Recursive<T extends Recursive<T>> {
  Recursive();
  bool get isLeaf => T == RecursiveLeaf;
}

class RecursiveLeaf extends Recursive<RecursiveLeaf> {}

@NAPI()
typedef SelfBound = Recursive<RecursiveLeaf>;

final _sessionCloses = <int, int>{};
final _sessionShutdowns = <int, int>{};
final _sessionCodes = <int, int>{};
final _sessionGates = <int, Completer<int>>{};
final _sessionWeak = <int, WeakReference<Object>>{};
final _sessionCancelGates = <int, Completer<void>>{};
final _sessionCancels = <int, int>{};
List<int> _sessionPressure = [];

Future<int> _holdSession(int token, Object owner) {
  _sessionWeak[token] = WeakReference(owner);
  final gate = Completer<int>();
  _sessionGates[token] = gate;
  // The business Future intentionally retains neither the owner nor its value.
  return gate.future;
}

class Session<T> {
  final int id;
  T value;
  Session(this.id, this.value);
  factory Session.from(int id, T value) => Session<T>(id, value);

  bool get isInt => T == int;
  bool get isDouble => T == double;
  Session<T> self() => this;
  Future<T> futureValue() => Future.value(value);
  Future<int> hold(int token) => _holdSession(token, this);

  Stream<T> watch(int token) {
    final item = value;
    final controller = StreamController<T>(
      onCancel: () {
        _sessionCancels.update(token, (count) => count + 1, ifAbsent: () => 1);
        final gate = Completer<void>();
        _sessionCancelGates[token] = gate;
        return gate.future;
      },
    );
    controller.add(item);
    return controller.stream;
  }

  void close([int code = 7, void Function()? failure]) {
    _sessionCloses.update(id, (count) => count + 1, ifAbsent: () => 1);
    _sessionCodes[id] = code;
    failure?.call();
  }

  Future<void> shutdown({bool fail = false}) async {
    _sessionShutdowns.update(id, (count) => count + 1, ifAbsent: () => 1);
    await Future<void>.delayed(Duration.zero);
    if (fail) throw StateError('session-shutdown-error');
  }
}

@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
typedef IntSession = Session<int>;

@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
typedef DoubleSession = Session<double>;

// The wider selected alias deliberately chooses a different cleanup policy.
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'shutdown')
typedef NullableSession = Session<int?>;

@NAPI(classPolicy: ClassPolicy.value)
typedef TextSessionValue = Session<String>;

@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
typedef NullableTextSession = Session<String?>;

@NAPI()
NullableTextSession createTextSession(int id, String value) =>
    Session<String>(id, value);
@NAPI()
TextSessionValue echoTextSessionValue(TextSessionValue value) => value;
@NAPI()
TextSessionValue projectTextSession(NullableTextSession owner) =>
    owner as TextSessionValue;
@NAPI()
Future<TextSessionValue> delayedTextSession(
  NullableTextSession owner,
  int token,
) async {
  await _holdSession(token, owner);
  return owner as TextSessionValue;
}

class Finish<T> {
  final int id;
  Finish(this.id);
  Future<T> close() {
    _sessionCloses.update(id, (count) => count + 1, ifAbsent: () => 1);
    return Future<T>.value();
  }
}

@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
typedef VoidSession = Finish<void>;

class DerivedSession extends Session<int> {
  DerivedSession(super.id, super.value);
  @override
  Type get runtimeType =>
      throw StateError('resource classifier read runtimeType');
}

@NAPI()
IntSession createSession(int id, int value) => DerivedSession(id, value);
@NAPI()
IntSession echoSession(IntSession value) => value;
@NAPI()
NullableSession widenedSession(int id) => Session<int>(id, 1);
@NAPI()
Future<int> holdSessions(List<IntSession> owners, int token) =>
    _holdSession(token, owners.first);
@NAPI()
bool finishSession(int token, int value) {
  _sessionGates.remove(token)!.complete(value);
  return true;
}

@NAPI()
bool finishSessionCancel(int token) {
  _sessionCancelGates.remove(token)!.complete();
  return true;
}

@NAPI()
int sessionCloses(int id) => _sessionCloses[id] ?? 0;
@NAPI()
int sessionShutdowns(int id) => _sessionShutdowns[id] ?? 0;
@NAPI()
int sessionCode(int id) => _sessionCodes[id] ?? -1;
@NAPI()
int sessionCancels(int token) => _sessionCancels[token] ?? 0;
@NAPI()
bool sessionAlive(int token) => _sessionWeak[token]?.target != null;

@NAPI()
int sessionPressure(int seed) {
  _sessionPressure = List<int>.generate(65536, (index) => index + seed);
  return _sessionPressure[seed & 65535];
}

int _valueConstructions = 0;
int _valueCalls = 0;

class ValueBox<T> {
  T value;
  ValueBox<T>? next;
  final int tag;
  ValueBox(this.value, {this.next, this.tag = 7}) {
    _valueConstructions++;
    if (value is int && (value as int) < 0) throw StateError('value-domain');
  }
  bool get isInt => T == int;
  bool get isDouble => T == double;
}

@NAPI(classPolicy: ClassPolicy.value)
typedef IntValue = ValueBox<int>;
@NAPI(classPolicy: ClassPolicy.value)
typedef TextValue = ValueBox<String>;
@NAPI(classPolicy: ClassPolicy.value)
typedef DoubleValue = ValueBox<double>;
@NAPI(classPolicy: ClassPolicy.value)
typedef NullableValue = ValueBox<String?>;
@NAPI(classPolicy: ClassPolicy.value)
typedef NestedValue = ValueBox<IntValue>;
@NAPI(classPolicy: ClassPolicy.value)
typedef LeafValue = ValueBox<Leaf>;
@NAPI(classPolicy: ClassPolicy.value)
typedef BytesValue = ValueBox<Uint8List>;
@NAPI(classPolicy: ClassPolicy.value)
typedef SharedValue = ValueBox<SharedBytes>;
@NAPI()
typedef ValueHandle = ValueBox<int?>;

class ParsedValue<T extends num> {
  final T value;
  ParsedValue(this.value);
}

class ParsedTextValue<T extends num> {
  final T value;
  ParsedTextValue.parse(String source)
    : value = (T == int ? int.parse(source) : double.parse(source)) as T;
}

@NAPI(classPolicy: ClassPolicy.value, valueFields: {'source': 'value'})
typedef ParsedInteger = ParsedTextValue<int>;
@NAPI(classPolicy: ClassPolicy.value)
typedef ParsedDouble = ParsedValue<double>;

abstract class Projected<T> {
  factory Projected(T value) = _Projected<T>;
  T get value;
}

class _Projected<T> implements Projected<T> {
  @override
  final T value;
  _Projected(this.value);
}

@NAPI(classPolicy: ClassPolicy.value)
typedef TextProjection = Projected<String>;

typedef _NullableObject = Object?;

class ValueMarker<T> {
  ValueMarker();
  bool get isObject => T == _NullableObject;
}

@NAPI(classPolicy: ClassPolicy.value)
typedef VoidValue = ValueMarker<void>;
@NAPI(classPolicy: ClassPolicy.value)
typedef ObjectValue = ValueMarker<Object?>;

@NAPI()
IntValue echoIntValue(IntValue value) {
  _valueCalls++;
  return value;
}

@NAPI()
(IntValue, TextValue, DoubleValue) valueTuple(
  (IntValue, TextValue, DoubleValue) value,
) => value;
@NAPI()
NullableValue? nullableValue(NullableValue? value) => value;
@NAPI()
NestedValue nestedValue(NestedValue value) => value;
@NAPI()
List<IntValue> repeatValue(IntValue value) => [value, value];
@NAPI()
Map<String, IntValue> valueMap(Map<String, IntValue> value) => value;
@NAPI()
Dictionary<TextValue> valueDictionary(Dictionary<TextValue> value) => value;
@NAPI()
LeafValue leafValue(LeafValue value) => value;
@NAPI()
BytesValue bytesValue(BytesValue value) => value;
@NAPI()
SharedValue sharedValue(SharedValue value) => value;
@NAPI()
ParsedInteger parseInteger(ParsedInteger value) => value;
@NAPI()
ParsedDouble parseDouble(ParsedDouble value) => value;
@NAPI()
TextProjection textProjection(TextProjection value) => value;
@NAPI()
(VoidValue, ObjectValue) valueMarkers(VoidValue first, ObjectValue second) =>
    (first, second);
@NAPI()
ValueHandle echoValueHandle(ValueHandle value) => value;
@NAPI()
ValueHandle createValueHandle() => ValueBox<int>(3);
@NAPI()
int twoValues(IntValue first, IntValue second) {
  _valueCalls++;
  return first.value + second.value;
}

@NAPI(bigint: true)
IntValue bigintValue(IntValue value) => value;
@NAPI()
int concreteValueConstructions() => _valueConstructions;
@NAPI()
int concreteValueCalls() => _valueCalls;
@NAPI()
IntValue cyclicValue() {
  final value = IntValue(1);
  value.next = value;
  return value;
}

@NAPI()
Future<IntValue> delayedValue(IntValue value) async {
  await Future<void>.delayed(const Duration(milliseconds: 5));
  return value;
}

@NAPI()
Stream<IntValue> valueEvents() {
  late StreamController<IntValue> controller;
  controller = StreamController<IntValue>(
    sync: true,
    onListen: () {
      scheduleMicrotask(() {
        final value = IntValue(1);
        controller.add(value);
        value.value = 2;
        controller.add(value);
        unawaited(controller.close());
      });
    },
  );
  return controller.stream;
}

@NAPI()
// The opaque name deliberately shadows a reference used inside the value schema.
// ignore: avoid_types_as_parameter_names
LeafValue valueShadow<Leaf>(LeafValue value, Leaf payload) => value;

class CellFeature<T> {
  T feature(T value) => value;
}

class CellMiddle<T> extends Cell<T> implements CellFeature<T> {
  CellMiddle(super.value);
  @override
  T feature(T value) => value;
}

class ChildCell<T> extends CellMiddle<T> {
  ChildCell(super.value);
  @override
  ChildCell<T> self() => this;
  @override
  int count([int value = 9]) => value;
}

@NAPI()
typedef IntCellFeature = CellFeature<int>;
@NAPI()
typedef DoubleCellFeature = CellFeature<double>;
@NAPI()
typedef IntChildCell = ChildCell<int>;
@NAPI()
typedef DoubleChildCell = ChildCell<double>;

class BatchMiddle<T> extends Cell<List<T>> {
  BatchMiddle(super.value);
}

class BatchChild<T> extends BatchMiddle<T> {
  BatchChild(super.value);
}

@NAPI()
typedef IntListCell = Cell<List<int>>;
@NAPI()
typedef IntBatchChild = BatchChild<int>;

class ChildSession<T> extends Session<T> {
  ChildSession(super.id, super.value);
  @override
  ChildSession<T> self() => this;
  @override
  // Cleanup selection intentionally names an own method on each resource view.
  // ignore: unnecessary_overrides
  void close([int code = 7, void Function()? failure]) =>
      super.close(code, failure);
}

@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
typedef IntChildSession = ChildSession<int>;
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
typedef DoubleChildSession = ChildSession<double>;

@NAPI()
IntCell createChildCell(int value) => IntChildCell(value);
@NAPI()
IntSession createChildSession(int id, int value) => IntChildSession(id, value);
@NAPI()
IntCellFeature echoCellFeature(IntCellFeature value) => value;
@NAPI()
IntListCell echoIntListCell(IntListCell value) => value;

@NAPI()
typedef NullableChildCell = ChildCell<int?>;

@NAPI()
class ExtraCellFeature {
  int extra() => 17;
}

class MixedChild extends ChildCell<int> implements ExtraCellFeature {
  MixedChild(super.value);
  @override
  int extra() => 17;
}

@NAPI()
IntCell createMixedChild(int value) => MixedChild(value);

// IntMiddle is deliberately not selected: the exact ancestor is only visible
// through the ordinary child, beside the selected wider generic middle.
class DeepMiddle<T> extends Cell<T> {
  DeepMiddle(super.value);
}

@NAPI()
typedef NullableMiddleCell = DeepMiddle<int?>;

@NAPI()
class DeepCell extends DeepMiddle<int> {
  DeepCell(super.value);
}

class MixedDeepCell extends DeepCell implements ExtraCellFeature {
  MixedDeepCell(super.value);
  @override
  int extra() => 18;
}

@NAPI()
IntCell createDeepCell(int value) => DeepCell(value);
@NAPI()
IntCell createMixedDeepCell(int value) => MixedDeepCell(value);

class DeepSessionMiddle<T> extends Session<T> {
  DeepSessionMiddle(super.id, super.value);
  // A selected resource names its own cleanup implementation.
  @override
  // ignore: unnecessary_overrides
  Future<void> shutdown({bool fail = false}) => super.shutdown(fail: fail);
}

@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'shutdown')
typedef NullableMiddleSession = DeepSessionMiddle<int?>;

// This ordinary child inherits its cleanup only from the selected IntSession.
@NAPI()
class DeepSession extends DeepSessionMiddle<int> {
  DeepSession(super.id, super.value);
  @override
  void close([int code = 7, void Function()? failure]) {
    super.close(code + 100, failure);
  }
}

class MixedDeepSession extends DeepSession implements ExtraCellFeature {
  MixedDeepSession(super.id, super.value);
  @override
  int extra() => 19;
}

@NAPI()
IntSession createDeepSession(int id, int value) => DeepSession(id, value);
@NAPI()
IntSession createMixedDeepSession(int id, int value) =>
    MixedDeepSession(id, value);

// An unselected narrower implementation is accepted through the selected wider
// child. That child's ancestor membership and resource policy must agree.
class HiddenMiddleCell extends DeepMiddle<int> {
  HiddenMiddleCell(super.value);
}

class MixedHiddenMiddleCell extends HiddenMiddleCell
    implements ExtraCellFeature {
  MixedHiddenMiddleCell(super.value);
  @override
  int extra() => 20;
}

@NAPI()
NullableMiddleCell createHiddenMiddleCell(int value) => HiddenMiddleCell(value);
@NAPI()
NullableMiddleCell createMixedHiddenMiddleCell(int value) =>
    MixedHiddenMiddleCell(value);

class SessionMiddle<T> extends Session<T> {
  SessionMiddle(super.id, super.value);
}

@NAPI()
typedef NullableSessionChild = SessionMiddle<int?>;

class HiddenSession extends SessionMiddle<int> {
  HiddenSession(super.id, super.value);
}

class MixedHiddenSession extends HiddenSession implements ExtraCellFeature {
  MixedHiddenSession(super.id, super.value);
  @override
  int extra() => 21;
}

@NAPI()
NullableSessionChild createHiddenSession(int id, int value) =>
    HiddenSession(id, value);
@NAPI()
NullableSessionChild createMixedHiddenSession(int id, int value) =>
    MixedHiddenSession(id, value);

class CrossView<T> {
  bool get isInt => T == int;
}

class LeftView<T> extends CrossView<T> {}

class RightView<T> extends CrossView<T> {}

@NAPI()
typedef IntCrossView = CrossView<int>;
@NAPI()
typedef NullableCrossView = CrossView<int?>;
@NAPI()
typedef NullableLeftView = LeftView<int?>;
@NAPI()
typedef IntRightView = RightView<int>;

@NAPI()
class SameAliasView extends CrossView<int?> {}

class CrossedView extends LeftView<int> implements RightView<int> {}

class CompatibleView extends LeftView<int?> implements SameAliasView {}

@NAPI()
NullableLeftView crossedView() => CrossedView();
@NAPI()
NullableLeftView compatibleView() => CompatibleView();

class CrossOwner<T> {
  final int id;
  CrossOwner(this.id);
  void close() =>
      _sessionCloses.update(id, (count) => count + 1, ifAbsent: () => 1);
}

class LeftOwner<T> extends CrossOwner<T> {
  LeftOwner(super.id);
}

class RightOwner<T> extends CrossOwner<T> {
  RightOwner(super.id);
}

@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
typedef IntCrossOwner = CrossOwner<int>;
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
typedef NullableCrossOwner = CrossOwner<int?>;
@NAPI()
typedef NullableLeftOwner = LeftOwner<int?>;
@NAPI()
typedef IntRightOwner = RightOwner<int>;

@NAPI()
class SameAliasOwner extends CrossOwner<int?> {
  SameAliasOwner(super.id);
}

class CrossedOwner extends LeftOwner<int> implements RightOwner<int> {
  CrossedOwner(super.id);
}

class CompatibleOwner extends LeftOwner<int?> implements SameAliasOwner {
  CompatibleOwner(super.id);
}

@NAPI()
NullableLeftOwner crossedOwner(int id) => CrossedOwner(id);
@NAPI()
NullableLeftOwner compatibleOwner(int id) => CompatibleOwner(id);

int _partialCloses = 0;

class PartialPair<A, B> {
  A first;
  B second;
  final String label;
  PartialPair(this.first, this.second, {this.label = 'pair'});
  PartialPair.named(this.first, this.second) : label = 'named';
  PartialPair<A, B> self() => this;
  T echo<T>(T value) => value;
  static T staticEcho<T>(T value) => value;
  Future<B> later() async {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return second;
  }

  void close() => _partialCloses++;
}

@NAPI()
typedef IntPair<T> = PartialPair<int, T>;
@NAPI()
typedef MaybeIntPair<T> = PartialPair<int?, T>;
@NAPI(classPolicy: ClassPolicy.value)
typedef TextPair<T> = PartialPair<String, T>;
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
typedef ResourcePair<T> = PartialPair<bool, T>;

@NAPI()
class PartialChild<T> extends PartialPair<int, T> {
  PartialChild(super.first, super.second);
}

@NAPI()
IntPair<U> echoPartial<U>(PartialPair<int, U> value) => value;
@NAPI()
MaybeIntPair<U> widenPartial<U>(IntPair<U> value) => value;
@NAPI()
TextPair<U> echoPartialValue<U>(TextPair<U> value) => value;
@NAPI()
int partialCloses() => _partialCloses;

class PartialTriple<A, B, C> {
  A first;
  B middle;
  C last;
  PartialTriple(this.first, this.middle, this.last);
  PartialTriple<A, B, C> self() => this;
}

@NAPI()
typedef FlippedPair<X, Y> = PartialTriple<Y, int, X>;
@NAPI()
FlippedPair<A, B> echoFlipped<A, B>(PartialTriple<B, int, A> value) => value;
