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
