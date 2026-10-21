import 'dart:async';

import 'package:napi/napi.dart';

final _events = <String>[];
final _gates = <int, Completer<int>>{};
final _weak = <int, WeakReference<ResourceView>>{};
final _cleanupCalls = <int, int>{};
final _cleanupCodes = <int, int>{};
ResourceCounter? _held;
WeakReference<ResourceOrphan>? _orphanCleanup;
List<int> _pressure = [];
int _uses = 0;
int _conflictCleanups = 0;

void _cleanup(int id, int code) {
  _cleanupCalls.update(id, (count) => count + 1, ifAbsent: () => 1);
  _cleanupCodes[id] = code;
  _events.add('close:$id:$code');
}

Future<int> _hold(int token, ResourceView value) {
  _weak[token] = WeakReference(value);
  final gate = Completer<int>();
  _gates[token] = gate;
  // Neither the gate nor its Future captures the resource.
  return gate.future;
}

@NAPI()
abstract class ResourceView {
  ResourceView._();
  int get value;
  int use([int amount = 1]);
  Future<int> hold(int token);
}

@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class ResourceCounter implements ResourceView {
  final int id;
  @override
  int value;
  ResourceCounter(this.id, [this.value = 0]);

  @override
  int use([int amount = 1]) {
    _uses++;
    return value += amount;
  }

  int read({int amount = 1}) {
    _events.add('read:$id');
    return value += amount;
  }

  @override
  Future<int> hold(int token) => _hold(token, this);

  Future<int> orphan(int token) {
    _weak[token] = WeakReference(this);
    return Completer<int>().future;
  }

  Future<int> later(int milliseconds) =>
      Future.delayed(Duration(milliseconds: milliseconds), () => value);

  Future<ResourceResult> result() => Future.value(ResourceResult(id));

  @NAPI(name: 'release')
  void close([int code = 7, ResourceCounter? same, List<int>? codes]) {
    if (same != null && !identical(same, this)) {
      throw StateError('resource-cleanup-wrong-self');
    }
    _cleanup(id, codes?.first ?? code);
    if (code < 0) throw StateError('resource-sync-cleanup-error');
  }
}

@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class ResourceAsync {
  final int id;
  ResourceAsync(this.id);
  int read() => id;

  Future<void> close({
    int code = 11,
    bool fail = false,
    int milliseconds = 0,
    ResourceCounter? dependency,
  }) async {
    _cleanup(id, code);
    if (dependency != null) _events.add('dependency:$id:${dependency.id}');
    await Future<void>.delayed(Duration(milliseconds: milliseconds));
    _events.add('done:$id');
    if (fail) throw StateError('resource-async-cleanup-error');
  }
}

@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class ResourceRequired {
  final int id;
  ResourceRequired(this.id);
  int read() => id;
  void close({required int? code}) => _cleanup(id, code ?? 13);
}

@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class ResourceOrphan {
  final int id;
  ResourceOrphan(this.id);
  Future<void> close() {
    _cleanup(id, 29);
    _orphanCleanup = WeakReference(this);
    return Completer<void>().future;
  }
}

@NAPI()
bool resourceOrphanCleanupAlive() => _orphanCleanup?.target != null;

@NAPI()
class ResourceResult {
  final int id;
  ResourceResult(this.id);
}

@NAPI()
class OrdinaryCounter {
  int value;
  OrdinaryCounter(this.value);
  int use() => ++value;
}

@NAPI(classPolicy: ClassPolicy.value)
class ResourceEnvelope {
  final ResourceView owner;
  final List<ResourceView?>? peers;
  ResourceEnvelope(this.owner, {this.peers});
}

const _valueOwner = ValueDefaultResource(300);
const _valuePeer = ValueDefaultResource(301);

@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class ValueDefaultResource {
  final int id;
  const ValueDefaultResource(this.id);
  void close() => _cleanup(id, 41);
}

@NAPI(classPolicy: ClassPolicy.value)
class ResourceDefaultValue {
  final ValueDefaultResource? owner;
  final List<ValueDefaultResource?> peers;
  final Map<String, ValueDefaultResource> mapping;
  final Dictionary<ValueDefaultResource?> labels;
  final (ValueDefaultResource, {ValueDefaultResource? other}) pair;
  final int marker;

  ResourceDefaultValue({
    this.owner = _valueOwner,
    this.peers = const [_valuePeer, null],
    this.mapping = const {'one': _valuePeer},
    this.labels = const Dictionary({'one': _valuePeer, 'empty': null}),
    this.pair = (_valuePeer, other: null),
    this.marker = 7,
  }) {
    _events.add('value-default-constructor');
    if (marker < 0) throw StateError('resource-default-constructor-error');
  }
}

@NAPI()
ResourceDefaultValue resourceDefaultEcho(ResourceDefaultValue value) {
  _events.add('value-default-business');
  return value;
}

@NAPI()
Future<int> resourceDefaultHold(
  ResourceDefaultValue value,
  void Function() later,
  int token,
) {
  _events.add('value-default-business');
  later();
  final gate = Completer<int>();
  _gates[token] = gate;
  return gate.future;
}

// The declarations are unrelated; only runtime membership reveals that one
// raw object has two incompatible cleanup contracts.
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'closeLeft')
abstract class ResourceLeft {
  ResourceLeft._();
  void closeLeft();
}

@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'closeRight')
abstract class ResourceRight {
  ResourceRight._();
  void closeRight();
}

class _Conflict implements ResourceLeft, ResourceRight {
  @override
  void closeLeft() => _conflictCleanups++;
  @override
  void closeRight() => _conflictCleanups++;
}

@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
abstract class ResourceVoidView {
  ResourceVoidView._();
  void close();
}

class _AsyncCleanup implements ResourceVoidView {
  final int id;
  final bool fail;
  _AsyncCleanup(this.id, this.fail);
  @override
  Future<void> close() async {
    _cleanup(id, 19);
    await Future<void>.delayed(const Duration(milliseconds: 15));
    _events.add('done:$id');
    if (fail) throw StateError('resource-override-cleanup-error');
  }
}

@NAPI()
ResourceVoidView resourceAsyncView(int id, {bool fail = false}) =>
    _AsyncCleanup(id, fail);

@NAPI()
ResourceLeft resourceConflict() => _Conflict();
@NAPI()
int resourceConflictCleanups() => _conflictCleanups;

@NAPI()
List<String> resourceEvents() => List.of(_events);
@NAPI()
int resourceCleanupCalls(int id) => _cleanupCalls[id] ?? 0;
@NAPI()
int resourceCleanupCode(int id) => _cleanupCodes[id] ?? -999;
@NAPI()
int resourceUses() => _uses;
@NAPI()
ResourceView resourceView(ResourceCounter value) => value;
@NAPI()
ResourceView resourceIdentity(ResourceView value) => value;
@NAPI()
int resourceUseView(ResourceView value) => value.use();
@NAPI()
Future<int> resourceHold(ResourceView value, int token) => _hold(token, value);
@NAPI()
int resourceDirectOrder(List<int> first, ResourceCounter later) {
  _events.add('direct-sync:${later.id}');
  return first.length + later.value;
}

@NAPI()
Future<int> resourceDirectOrderFuture(
  List<int> first,
  ResourceCounter later,
  int token,
) {
  _events.add('direct-future:${later.id}:${first.length}');
  return _hold(token, later);
}

@NAPI()
Future<int> resourceHoldList(List<ResourceView?> values, int token) =>
    _hold(token, values.first!);
@NAPI()
Future<int> resourceHoldMap(Map<String, ResourceView> values, int token) =>
    _hold(token, values.values.first);
@NAPI()
Future<int> resourceHoldDictionary(
  Dictionary<ResourceView?> values,
  int token,
) => _hold(token, values.values.first!);
@NAPI()
Future<int> resourceHoldRecord(
  (ResourceView, {ResourceView? other}) value,
  int token,
) => _hold(token, value.$1);
@NAPI()
Future<int> resourceHoldEnvelope(ResourceEnvelope value, int token) =>
    _hold(token, value.owner);
@NAPI()
Future<(ResourceView, int)> resourceBadResult(ResourceView value) =>
    Future.value((value, 9007199254740992));
@NAPI()
Future<T> resourceOpaqueResult<T>(ResourceView owner, T value) =>
    Future.value(value);
@NAPI()
int resourceComplete(int token, [int value = 42]) {
  _gates.remove(token)!.complete(value);
  return token;
}

@NAPI()
bool resourceAlive(int token) => _weak[token]?.target != null;
@NAPI()
int resourceKeep(ResourceCounter value) {
  _held = value;
  return value.id;
}

@NAPI()
ResourceCounter resourceHeld() => _held!;
@NAPI()
ResourceView resourceHeldView() => _held!;
@NAPI()
int resourceForget() {
  _held = null;
  return 0;
}

@NAPI()
int resourcePressure(int seed) {
  _pressure = List<int>.generate(65536, (index) => index + seed);
  return _pressure[seed & 65535];
}
