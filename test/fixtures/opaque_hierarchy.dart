import 'dart:async';

import 'package:napi/napi.dart';

Object? _root;
int _constructions = 0;
Completer<int>? _waiting;

@NAPI()
class OpaqueBase<T> {
  T value;
  OpaqueBase(this.value) {
    _constructions++;
  }
  T read() => value;
  void write(T next) => value = next;
  OpaqueBase<T> self() => this;
  T? optional([T? input]) => input;
  T? choose({T? first, T? second, int index = 7}) =>
      index == 7 ? first : second;
  Future<T> later() async => value;
  Stream<T> values() async* {
    yield value;
  }

  Future<int> wait(T input) {
    // This closure deliberately retains neither the supplied payload nor this.
    _waiting = Completer<int>();
    return _waiting!.future;
  }

  void pin() => _root = this;
}

@NAPI()
class OpaqueChild<U> extends OpaqueBase<U> {
  OpaqueChild(super.value);
  @override
  U read() => value;
  @override
  OpaqueChild<U> self() => this;
  @override
  U? optional([U? input, U? extra]) => input;
}

@NAPI()
class OpaqueTagged<T, Meta> extends OpaqueBase<T> {
  Meta meta;
  OpaqueTagged(super.value, this.meta);
  @override
  OpaqueTagged<T, Meta> self() => this;
}

@NAPI()
class OpaqueTaggedLeaf<Meta, Extra, T> extends OpaqueTagged<T, Meta> {
  Extra extra;
  OpaqueTaggedLeaf(super.value, super.meta, this.extra);
}

@NAPI()
OpaqueBase<T> opaqueTaggedBase<T, Meta>(OpaqueTagged<T, Meta> value) => value;

int _resourceCleanups = 0;

@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class OpaqueResourceBase {
  OpaqueResourceBase();
  Future<int> wait() {
    _waiting = Completer<int>();
    return _waiting!.future;
  }

  void close() => _resourceCleanups++;
}

@NAPI()
class OpaqueResourceChild<T> extends OpaqueResourceBase {
  T value;
  OpaqueResourceChild(this.value);
  T read() => value;
}

@NAPI()
OpaqueResourceBase opaqueAsResource<T>(OpaqueResourceChild<T> value) => value;
@NAPI()
int opaqueResourceCleanups() => _resourceCleanups;

@NAPI()
class OpaquePair<A, B> {
  A first;
  B second;
  OpaquePair(this.first, this.second);
  OpaquePair<A, B> self() => this;
  B readSecond() => second;
  JsArray<A> writeArray(JsArray<A> values, A value) {
    values.set(0, value);
    return values;
  }

  JsMap<A, B> writeMap(JsMap<A, B> values, A key, B value) {
    values.set(key, value);
    return values;
  }
}

@NAPI()
class OpaqueSlot<A, B> {
  B slot;
  OpaqueSlot(this.slot);
}

class _PairMiddle<M, N> extends OpaquePair<N, M> implements OpaqueSlot<N, M> {
  _PairMiddle(super.first, super.second);
  @override
  M get slot => second;
  @override
  set slot(M value) => second = value;
  @override
  M readSecond() => second;
}

@NAPI()
class OpaquePairChild<X, Y> extends _PairMiddle<X, Y> {
  OpaquePairChild(super.first, super.second);
  @override
  OpaquePairChild<X, Y> self() => this;
  @override
  JsMap<Y, X> writeMap(JsMap<Y, X> values, Y key, X value) {
    final result = super.writeMap(values, key, value);
    first = key;
    second = value;
    return result;
  }

  @override
  set slot(X value) => second = value;
}

@NAPI()
class OpaqueLeaf<P, Q> extends OpaquePairChild<Q, P> {
  OpaqueLeaf(super.first, super.second);
}

@NAPI()
class OpaqueThen<T> {
  @NAPI(name: 'then')
  T hook;
  OpaqueThen(this.hook);
}

@NAPI()
class OpaqueThenChild<U> extends OpaqueThen<U> {
  OpaqueThenChild(super.hook);
  Future<OpaqueThenChild<U>> later() async => this;
}

@NAPI()
OpaqueBase<U> opaqueAsBase<U>(OpaqueChild<U> value) => value;
@NAPI()
OpaquePair<Y, X> opaqueAsPair<X, Y>(OpaquePairChild<X, Y> value) => value;
@NAPI()
OpaqueSlot<Y, X> opaqueAsSlot<X, Y>(OpaquePairChild<X, Y> value) => value;
@NAPI()
OpaqueBase<T> opaqueReadBase<T>() => _root as OpaqueBase<T>;
@NAPI()
OpaqueChild<T> opaqueReadChild<T>() => _root as OpaqueChild<T>;
@NAPI()
void opaqueUnpin() => _root = null;
@NAPI()
int opaqueConstructions() => _constructions;
@NAPI()
void opaqueComplete(int value) => _waiting!.complete(value);
@NAPI()
OpaqueBase<T> opaqueBadExposure<T>(T value) {
  final child = OpaqueChild(value);
  _root = child;
  throw StateError('pinned before exposure');
}

@NAPI()
class OpaqueWrite<T> {
  T? _part;
  OpaqueWrite();
  set part(T value) => _part = value;
}

@NAPI()
class OpaqueRead<U> extends OpaqueWrite<U> {
  OpaqueRead();
  U? get part => _part;
}
