import 'dart:async';

import 'package:napi/napi.dart';

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
