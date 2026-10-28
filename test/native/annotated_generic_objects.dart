import 'package:napi/napi.dart';

@NAPI.object()
class FutureEnvelope<T> {
  @NAPI()
  FutureEnvelope({required this.value});

  @NAPI()
  final Future<T> value;
}

@NAPI.object()
class FutureProducer<T> {
  @NAPI()
  FutureProducer({required this.create});

  @NAPI()
  final Future<T> Function() create;
}

@NAPI()
FutureProducer<Future<int>> nestedFutureProducer(
  FutureProducer<Future<int>> value,
) => value;

@NAPI()
FutureProducer<Future<Amount>> nestedAmountFutureProducer(
  FutureProducer<Future<Amount>> value,
) => value;

@NAPI()
FutureEnvelope<Future<int>> nestedFutures(FutureEnvelope<Future<int>> value) =>
    value;

@NAPI()
FutureEnvelope<Future<Amount>> nestedAmountFutures(
  FutureEnvelope<Future<Amount>> value,
) => value;

@NAPI()
FutureEnvelope<Future<int>?> nullableNestedFutures(
  FutureEnvelope<Future<int>?> value,
) => value;

@NAPI()
Envelope<FutureEnvelope<Future<int>>> nestedFutureEnvelope(
  Envelope<FutureEnvelope<Future<int>>> value,
) => value;

const _note = 'kept';

@NAPI.object()
class Envelope<T> {
  @NAPI()
  Envelope({required this.value, this.optional, this.note = _note});

  @NAPI()
  final T value;
  @NAPI()
  final T? optional;
  @NAPI()
  final String note;
  @NAPI()
  bool get intType => T == int;
  @NAPI()
  bool get stringType => T == String;
  @NAPI()
  bool get isDoubleType => T == double;
}

@NAPI.object()
class Point {
  @NAPI()
  Point({required String value}) : value = int.parse(value);

  @NAPI()
  final int value;
}

@NAPI.object()
class Amount {
  @NAPI()
  Amount({required String value}) : value = int.parse(value);

  @NAPI()
  final int value;
}

@NAPI.object()
class Handler<T> {
  @NAPI()
  Handler({required this.run});

  @NAPI()
  final T Function(T) run;
}

@NAPI.object()
class FnHolder {
  @NAPI()
  FnHolder({required this.run});

  @NAPI()
  final T Function<T>(T) run;
}

@NAPI.object()
class AsyncFnHolder {
  @NAPI()
  AsyncFnHolder({required this.run});

  @NAPI()
  final Future<T> Function<T>(T) run;
}

@NAPI.object()
class AsyncBoundFnHolder {
  @NAPI()
  AsyncBoundFnHolder({required this.run});

  @NAPI()
  final Future<T> Function<T extends num>(T) run;
}

@NAPI.object()
class Chain {
  @NAPI()
  Chain({required this.next});

  @NAPI()
  final Chain Function() next;
}

@NAPI.object()
class NullableNext {
  @NAPI()
  // ignore: prefer_initializing_formals
  NullableNext({required NullableNext? next}) : _next = next;

  final NullableNext? _next;
  @NAPI()
  NullableNext get next => _next ?? this;
}

@NAPI.object()
class ListNextChain {
  @NAPI()
  // ignore: prefer_initializing_formals
  ListNextChain({required List<ListNextChain?>? next}) : _next = next;

  final List<ListNextChain?>? _next;
  @NAPI()
  ListNextChain? get next => _next?.firstOrNull;
}

@NAPI.object()
class OpaqueNext {
  @NAPI()
  OpaqueNext({required Object next});

  @NAPI()
  OpaqueNext? get next => null;
}

@NAPI.object()
class ReferenceNext {
  @NAPI()
  ReferenceNext({required JsReference<JsObject>? next});

  @NAPI()
  ReferenceNext? get next => null;
}

@NAPI.object()
class DistinctNext {
  @NAPI()
  DistinctNext({required NestedOther next});

  @NAPI()
  DistinctNext get next => this;
}

@NAPI.object()
class RecordNext {
  @NAPI()
  RecordNext({required ({int value}) next}) : _value = next.value;

  final int _value;
  @NAPI()
  RecordNext get next => this;
}

@NAPI.object()
class MapNext {
  @NAPI()
  MapNext({required Map<String, int> next}) : _value = next['value'];

  final int? _value;
  @NAPI()
  MapNext get next => this;
}

@NAPI.object()
class DateNext {
  @NAPI()
  DateNext({required DateTime next})
    : _milliseconds = next.millisecondsSinceEpoch;

  final int _milliseconds;
  @NAPI()
  DateNext get next => this;
}

@NAPI.object()
class StreamNext {
  @NAPI()
  // ignore: prefer_initializing_formals
  StreamNext({required Stream<int> next}) : _next = next;

  final Stream<int> _next;
  @NAPI()
  StreamNext get next => this;
}

@NAPI.object()
class RawStreamNext {
  @NAPI()
  RawStreamNext({required JsReference<JsObject> next});

  @NAPI()
  Stream<RawStreamNext> get next => const Stream.empty();
}

@NAPI()
class NativeValue {
  @NAPI()
  NativeValue();
}

@NAPI.object()
class NativeNext {
  @NAPI()
  // ignore: prefer_initializing_formals
  NativeNext({required NativeValue next}) : _value = next;

  final NativeValue _value;
  @NAPI()
  NativeNext get next => this;
}

@NAPI.object()
class GenericNext<T> {
  @NAPI()
  // ignore: prefer_initializing_formals
  GenericNext({required T next}) : _value = next;

  final T _value;
  @NAPI()
  GenericNext<T> get next => this;
}

@NAPI.object()
class FunctionNext {
  @NAPI()
  FunctionNext({required void Function() next}) {
    next();
  }

  @NAPI()
  FunctionNext get next => this;
}

@NAPI.object()
class OptionalMapInput {
  @NAPI()
  OptionalMapInput({this.child});

  @NAPI()
  final OptionalMapChain? child;
}

@NAPI.object()
class OptionalMapChain {
  @NAPI()
  OptionalMapChain({required OptionalMapInput next});

  @NAPI()
  Map<String, OptionalMapChain> get next => {};
}

@NAPI.object()
class NestedOther {
  @NAPI()
  NestedOther(this.next);

  @NAPI()
  final ScalarValue next;
}

@NAPI.object()
class Empty {
  @NAPI()
  Empty();
}

@NAPI.object()
class EmptyReferenceView {
  @NAPI()
  EmptyReferenceView({required JsReference<JsObject>? value})
    : value = value == null ? null : Empty();

  @NAPI()
  final Empty? value;
}

@NAPI.object()
class Stringifier {
  @NAPI()
  // ignore: prefer_initializing_formals
  Stringifier({required String Function() toString}) : _toString = toString;

  final String Function() _toString;
  @NAPI(name: 'toString')
  String Function() get value => _toString;
}

@NAPI.object()
class StringifierView {
  @NAPI()
  StringifierView({required Empty value})
    : value = Stringifier(toString: () => 'ok');

  @NAPI()
  final Stringifier value;
}

@NAPI.object()
class ScalarValue {
  @NAPI()
  ScalarValue(this.value);

  @NAPI()
  final int value;
}

@NAPI.object()
class RecordValue {
  @NAPI()
  RecordValue({required ({int value}) value})
    : value = ScalarValue(value.value);

  @NAPI()
  final ScalarValue value;
}

@NAPI.object()
class IntegerValue {
  @NAPI()
  IntegerValue(this.value);

  @NAPI()
  final int value;
}

@NAPI.object()
class ClassValueView {
  @NAPI()
  ClassValueView({required ScalarValue value})
    : value = IntegerValue(value.value);

  @NAPI()
  final IntegerValue value;
}

@NAPI.object()
class AmountValueView {
  @NAPI()
  AmountValueView({required ScalarValue value})
    : value = Amount(value: '${value.value}');

  @NAPI()
  final Amount value;
}

@NAPI.object()
class LinkedA {
  @NAPI()
  LinkedA({required LinkedB? next})
    : next = next == null ? null : LinkedA(next: next.next);

  @NAPI()
  final LinkedA? next;
}

@NAPI.object()
class LinkedB {
  @NAPI()
  LinkedB({required this.next});

  @NAPI()
  final LinkedB? next;
}

@NAPI.object()
class FunctionLoop<T> {
  @NAPI()
  FunctionLoop({required List<T> value, required this.next})
    : value = value.first;

  @NAPI()
  final T value;
  @NAPI()
  final FunctionLoop<T Function()>? next;
}

@NAPI.object()
class RecordLoop<T> {
  @NAPI()
  RecordLoop({required List<T> value, required this.next})
    : value = value.first;

  @NAPI()
  final T value;
  @NAPI()
  final RecordLoop<(T,)>? next;
}

@NAPI.object()
class AsyncChain {
  @NAPI()
  AsyncChain({required this.next});

  @NAPI()
  final Future<AsyncChain?> next;
}

@NAPI.object()
class FutureCallbackChain {
  @NAPI()
  FutureCallbackChain({required this.next});

  @NAPI()
  final Future<FutureCallbackChain Function()> next;
}

@NAPI.object()
class FutureMapChain {
  @NAPI()
  FutureMapChain({required this.next});

  @NAPI()
  final Future<Map<String, FutureMapChain Function()>> next;
}

@NAPI.object()
class ConcreteCycleA {
  @NAPI()
  ConcreteCycleA({required String value, required this.next})
    : value = int.parse(value);

  @NAPI()
  final int value;
  @NAPI()
  final ConcreteCycleB? next;
}

@NAPI.object()
class ConcreteCycleB {
  @NAPI()
  ConcreteCycleB({required this.value, required this.next});

  @NAPI()
  final Future<int> value;
  @NAPI()
  final ConcreteCycleA? next;
}

@NAPI.object()
class Stabilizing<T, U> {
  @NAPI()
  Stabilizing({required T? a, required U? b, required this.next})
    : a = a!,
      b = b!;

  @NAPI()
  final T a;
  @NAPI()
  final U b;
  @NAPI()
  final Stabilizing<T, List<T>>? next;
}

@NAPI.object()
class Alternating<A, B> {
  @NAPI()
  Alternating({
    required B value,
    required this.output,
    required Alternating<A, A>? next,
  });

  @NAPI()
  A get value => output;
  @NAPI()
  final A output;
  @NAPI()
  Alternating<List<B>, B>? get next => null;
}

@NAPI.object()
class BoundHolder<U> {
  @NAPI()
  BoundHolder({required this.run});

  @NAPI()
  final T Function<T extends U>(T) run;
}

@NAPI.object()
class ScopedBoundBox<T> {
  @NAPI()
  // ignore: prefer_initializing_formals
  ScopedBoundBox({required U Function<U extends T>(U) run}) : _run = run;

  final U Function<U extends T>(U) _run;
  @NAPI()
  List<U Function<U extends T>(U)> get run => [_run];
}

@NAPI.object()
class ScopedBoundHost {
  @NAPI()
  ScopedBoundHost({required this.box});

  @NAPI()
  final ScopedBoundBox<num> box;
}

@NAPI.object()
class ScalarBox<T> {
  @NAPI()
  ScalarBox({required this.run});

  @NAPI()
  final Future<U> Function<U extends T>(U) run;
}

@NAPI.object()
class ScalarHost {
  @NAPI()
  ScalarHost({required this.box});

  @NAPI()
  final ScalarBox<num> box;
}

@NAPI.object()
class ScopeLoop {
  @NAPI()
  ScopeLoop({required this.run, required this.next});

  @NAPI()
  final Future<T> Function<T>(T) run;
  @NAPI()
  final ScopeLoop Function<U>() next;
}

@NAPI.object()
class StringInput {
  @NAPI()
  // ignore: prefer_initializing_formals
  StringInput({required String value}) : value = value;

  @NAPI()
  final dynamic value;
}

@NAPI.object()
class ThenableAmount {
  @NAPI()
  ThenableAmount({required String value}) : value = int.parse(value);

  @NAPI()
  final int value;
  @NAPI()
  void Function(void Function(int)) get then =>
      (resolve) => resolve(value);
}

@NAPI.object()
class ThenableRecord {
  @NAPI()
  // ignore: prefer_initializing_formals
  ThenableRecord({required int value}) : _value = value;

  final int _value;
  @NAPI()
  void Function(void Function(({int value}))) get then =>
      (resolve) => resolve((value: _value));
}

@NAPI.object()
class ThenableRecordHolder {
  @NAPI()
  ThenableRecordHolder({required this.future});

  @NAPI()
  final Future<ThenableRecord> future;
}

@NAPI.object()
class ThenableChain {
  @NAPI()
  ThenableChain({required this.then, required this.next});

  @NAPI()
  final void Function(void Function(int)) then;
  @NAPI()
  final Future<ThenableChain?> next;
}

@NAPI.object()
class NullableThenChain {
  @NAPI()
  NullableThenChain({required this.then, required this.next});

  @NAPI()
  final void Function(void Function(int))? then;
  @NAPI()
  final Future<NullableThenChain?> next;
}

@NAPI.object()
class FiniteThenable<T> {
  @NAPI()
  // ignore: prefer_initializing_formals
  FiniteThenable({required T value}) : _value = value;

  final T _value;
  @NAPI()
  void Function(void Function(T)) get then =>
      (resolve) => resolve(_value);
}

@NAPI.object()
class FiniteThenableHost {
  @NAPI()
  FiniteThenableHost({required this.future});

  @NAPI()
  final Future<FiniteThenable<FiniteThenable<int>>> future;
}

@NAPI.object()
class Readout<T> {
  Readout(this.value);

  @NAPI()
  final T value;
}

@NAPI.object()
class Producer<T> {
  @NAPI()
  Producer({required this.create});

  @NAPI()
  final T Function() create;
}

@NAPI.object()
class Recursive<T> {
  @NAPI()
  Recursive({required this.value, this.next});

  @NAPI()
  final T value;
  @NAPI()
  final Recursive<List<T>>? next;
}

@NAPI.object()
class Swap<A, B> {
  @NAPI()
  Swap({required this.value, required this.next});

  @NAPI()
  final A value;
  @NAPI()
  final Swap<B, A>? next;
}

typedef NestedObjectCallback = void Function(Handler<Amount Function(Amount)>);

@NAPI()
Envelope<int> echoInt(Envelope<int> value) => value;

@NAPI()
Envelope<String> echoText(Envelope<String> value) => value;

@NAPI()
Envelope<double> echoDouble(Envelope<double> value) => value;

@NAPI()
Envelope<T> echo<T>(Envelope<T> value) => value;

@NAPI()
Envelope<Point> echoPoint(Envelope<Point> value) => value;

@NAPI()
Envelope<int>? nullable([Envelope<int>? value]) => value;

@NAPI()
Envelope<Point> Function(Envelope<Point>) bounce(
  Envelope<Point> Function(Envelope<Point>) callback,
) => callback;

@NAPI()
Future<Map<String, List<Envelope<Point>?>>> groups(
  Future<Map<String, List<Envelope<Point>?>>> value,
) => value;

@NAPI()
Readout<int> readout() => Readout(7);

@NAPI()
Readout<Readout<int>> nestedReadout() => Readout(Readout(7));

@NAPI()
Producer<int> echoIntProducer(Producer<int> value) => value;

@NAPI()
Producer<Point> echoPointProducer(Producer<Point> value) => value;

@NAPI()
Recursive<int> echoRecursive(Recursive<int> value) => value;

@NAPI()
Handler<int> echoIntHandler(Handler<int> value) => value;

@NAPI()
Handler<Amount> echoAmountHandler(Handler<Amount> value) => value;

@NAPI()
Handler<T> echoHandler<T>(Handler<T> value) => value;

@NAPI()
Handler<Amount> nativeHandler() =>
    Handler(run: (value) => Amount(value: '${value.value + 1}'));

@NAPI()
Handler<AmountValueView> nativeAmountValueHandler() =>
    Handler(run: (value) => value);

@NAPI()
Handler<List<Amount>> nativeListHandler() => Handler(run: (value) => value);

@NAPI()
Handler<Map<String, Amount>> nativeMapHandler() =>
    Handler(run: (value) => value);

@NAPI()
Handler<Amount Function(Amount)> nativeFunctionHandler() =>
    Handler(run: (value) => value);

@NAPI()
Handler<Swap<int, Amount> Function()> nativeSwapHandler() =>
    Handler(run: (value) => value);

@NAPI()
NestedObjectCallback getNestedCallback() => (handler) {
  final transform = handler.run(
    (amount) => Amount(value: '${amount.value + 1}'),
  );
  transform(Amount(value: '7'));
};

@NAPI()
Handler<NestedObjectCallback> nativeNestedCallbackHandler() =>
    Handler(run: (value) => value);

@NAPI()
Handler<Future<Amount>> nativeFutureHandler() => Handler(run: (value) => value);

@NAPI()
FnHolder echoFnHolder(FnHolder value) => value;

@NAPI()
AsyncFnHolder echoAsyncFnHolder(AsyncFnHolder value) => value;

@NAPI()
Future<int> applyAsyncFnHolder(AsyncFnHolder value, int input) =>
    value.run<int>(input);

@NAPI()
Future<bool> asyncScalarBound(AsyncBoundFnHolder holder) async =>
    (await holder.run<double>(3)).runtimeType == double;

@NAPI()
Chain echoChain(Chain value) => value;

@NAPI()
bool nullableNextUsesSelf(NullableNext value) => identical(value.next, value);

@NAPI()
ListNextChain echoListNextChain(ListNextChain value) => value;

@NAPI()
OpaqueNext echoOpaqueNext(OpaqueNext value) => value;

@NAPI()
ReferenceNext echoReferenceNext(ReferenceNext value) => value;

@NAPI()
bool distinctNextUsesSelf(DistinctNext value) => identical(value.next, value);

@NAPI()
bool recordNextMatches(RecordNext value, int expected) =>
    value._value == expected && identical(value.next, value);

@NAPI()
bool mapNextMatches(MapNext value, int expected) =>
    value._value == expected && identical(value.next, value);

@NAPI()
bool dateNextMatches(DateNext value, int expected) =>
    value._milliseconds == expected && identical(value.next, value);

@NAPI()
Future<bool> streamNextMatches(StreamNext value, int expected) async =>
    await value._next.first == expected && identical(value.next, value);

@NAPI()
RawStreamNext echoRawStreamNext(RawStreamNext value) => value;

@NAPI()
bool nativeNextMatches(NativeNext value, NativeValue expected) =>
    identical(value._value, expected) && identical(value.next, value);

@NAPI()
bool genericNextUsesSelf<T>(GenericNext<T> value) =>
    identical(value.next, value);

@NAPI()
T genericNextInput<T>(GenericNext<T> value) => value._value;

@NAPI()
bool functionNextUsesSelf(FunctionNext value) => identical(value.next, value);

@NAPI()
OptionalMapChain echoOptionalMapChain(OptionalMapChain value) => value;

@NAPI()
EmptyReferenceView echoEmptyReferenceView(EmptyReferenceView value) => value;

@NAPI()
StringifierView echoStringifierView(StringifierView value) => value;

@NAPI()
RecordValue echoRecordValue(RecordValue value) => value;

@NAPI()
ClassValueView echoClassValueView(ClassValueView value) => value;

@NAPI()
LinkedA echoLinkedA(LinkedA value) => value;

@NAPI()
FunctionLoop<int> echoFunctionLoop(FunctionLoop<int> value) => value;

@NAPI()
RecordLoop<int> echoRecordLoop(RecordLoop<int> value) => value;

@NAPI()
AsyncChain echoAsyncChain(AsyncChain value) => value;

@NAPI()
FutureCallbackChain echoFutureCallbackChain(FutureCallbackChain value) => value;

@NAPI()
FutureMapChain echoFutureMapChain(FutureMapChain value) => value;

@NAPI()
Future<Map<String, void Function(void Function(int))>> resolverMap(
  bool thenKey,
) async => {thenKey ? 'then' : 'one': (resolve) => resolve(thenKey ? 7 : 9)};

@NAPI()
Future<Map<String, int Function()>> scalarThenMap(
  int Function() callback,
) async => {'then': callback};

@NAPI()
ConcreteCycleA echoConcreteCycle(ConcreteCycleA value) => value;

@NAPI()
Stabilizing<int, String> echoStabilizing(Stabilizing<int, String> value) =>
    value;

@NAPI()
Alternating<int, String> echoAlternating(Alternating<int, String> value) =>
    value;

@NAPI()
int applyFnHolder(FnHolder value, int input) => value.run<int>(input);

@NAPI()
bool scalarBound(BoundHolder<num> holder) =>
    holder.run<double>(3).runtimeType == double;

@NAPI()
ScopedBoundHost echoScopedBoundHost(ScopedBoundHost value) => value;

@NAPI()
bool invokeScopedBoundHost(ScopedBoundHost value) =>
    value.box.run.single<double>(3).runtimeType == double;

@NAPI()
ScalarHost echoScalarHost(ScalarHost value) => value;

@NAPI()
Future<bool> invokeScalarHost(ScalarHost value) async =>
    (await value.box.run<double>(3)).runtimeType == double;

@NAPI()
ScopeLoop echoScopeLoop(ScopeLoop value) => value;

@NAPI()
Handler<StringInput> nativeStringHandler() => Handler(run: (value) => value);

@NAPI()
Handler<Future<ThenableAmount>> nativeThenableHandler() =>
    Handler(run: (value) => value);

@NAPI()
ThenableRecordHolder echoThenableRecordHolder(ThenableRecordHolder value) =>
    value;

@NAPI()
ThenableChain echoThenableChain(ThenableChain value) => value;

@NAPI()
NullableThenChain echoNullableThenChain(NullableThenChain value) => value;

@NAPI()
Future<NullableThenChain> asyncEchoNullableThenChain(
  NullableThenChain value,
) async => value;

@NAPI()
FiniteThenableHost echoFiniteThenableHost(FiniteThenableHost value) => value;

@NAPI()
Amount applyAmount(Amount value, Handler<Amount> handler) => handler.run(value);

@NAPI()
Envelope<Handler<Amount>> nestedHandler(Envelope<Handler<Amount>> value) =>
    value;
