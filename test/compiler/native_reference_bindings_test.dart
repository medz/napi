import 'dart:ffi';

import 'package:napi/src/compiler/native/bindings.dart';
import 'package:test/test.dart';

typedef _CallocNative = Pointer<Void> Function(Size, Size);
typedef _Calloc = Pointer<Void> Function(int, int);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _Free = void Function(Pointer<Void>);
typedef _Wrap = Int32 Function(Pointer<Void>, Pointer<Void>, Int64);
typedef _Unwrap = Int64 Function(Pointer<Void>, Pointer<Void>);
typedef _Value = Int32 Function(Pointer<Void>, Int64, Pointer<Pointer<Void>>);
typedef _Create = Int32 Function(
  Pointer<Void>,
  Uint32,
  Int64,
  Pointer<Pointer<Void>>,
);

final _libc = DynamicLibrary.process();
final _calloc = _libc.lookupFunction<_CallocNative, _Calloc>('calloc');
final _free = _libc.lookupFunction<_FreeNative, _Free>('free');

// Test the Dart lease protocol through actual FFI calls. These callbacks model
// cache expiry/finalizer ordering; real Node weak references and teardown are
// covered by the generated native integration contract.
final class _Table {
  final table = _calloc(35, sizeOf<Pointer<Void>>()).cast<Pointer<Void>>();
  final byLease = <int, int>{};
  final byPointer = <int, int>{};
  final creations = <(int, int)>[];
  var nextPointer = 1000;
  var lastLease = 0;
  var failWrap = false;
  var failCreate = false;
  late final NativeCallable<_Wrap> wrap;
  late final NativeCallable<_Unwrap> unwrap;
  late final NativeCallable<_Value> value;
  late final NativeCallable<_Create> create;
  late final NapiApi api;
  final env = Pointer<Void>.fromAddress(1);

  _Table() {
    if (table == nullptr) throw StateError('Cannot allocate test table');
    wrap = NativeCallable<_Wrap>.isolateLocal((
      Pointer<Void> env,
      Pointer<Void> self,
      int lease,
    ) {
      lastLease = lease;
      if (failWrap) return 1;
      byLease[lease] = self.address;
      byPointer[self.address] = lease;
      return 0;
    }, exceptionalReturn: 1);
    unwrap = NativeCallable<_Unwrap>.isolateLocal(
      (Pointer<Void> env, Pointer<Void> input) => byPointer[input.address] ?? 0,
      exceptionalReturn: 0,
    );
    value = NativeCallable<_Value>.isolateLocal((
      Pointer<Void> env,
      int lease,
      Pointer<Pointer<Void>> out,
    ) {
      out.value = Pointer<Void>.fromAddress(byLease[lease] ?? 0);
      return 0;
    }, exceptionalReturn: 1);
    create = NativeCallable<_Create>.isolateLocal((
      Pointer<Void> env,
      int classId,
      int lease,
      Pointer<Pointer<Void>> out,
    ) {
      lastLease = lease;
      if (failCreate) return 1;
      final pointer = ++nextPointer;
      byLease[lease] = pointer;
      byPointer[pointer] = lease;
      creations.add((classId, lease));
      out.value = Pointer<Void>.fromAddress(pointer);
      return 0;
    }, exceptionalReturn: 1);
    table[14] = wrap.nativeFunction.cast();
    table[15] = unwrap.nativeFunction.cast();
    table[28] = value.nativeFunction.cast();
    table[29] = create.nativeFunction.cast();
    api = NapiApi(table.address, 35);
  }

  NapiCall call(int self) => NapiCall(
    env,
    Pointer<Void>.fromAddress(2),
    Pointer<Void>.fromAddress(self),
    const [],
    0,
  );

  void expire(int lease) {
    final pointer = byLease.remove(lease);
    if (pointer != null) byPointer.remove(pointer);
  }

  void close() {
    create.close();
    value.close();
    unwrap.close();
    wrap.close();
    _free(table.cast());
  }
}

final class _EqualValue {
  @override
  bool operator ==(Object other) => other is _EqualValue;
  @override
  int get hashCode => 0;
}

void main() {
  late _Table bridge;
  setUp(() {
    bridge = _Table();
    addTearDown(bridge.close);
  });

  test('reachable wrappers reuse identity across outputs and factory new', () {
    final object = Object();
    final first = bridge.api.referenceResult(bridge.env, object, 2, 'create');
    expect(bridge.api.referenceResult(bridge.env, object, 2, 'again'), first);
    expect(bridge.api.wrap(bridge.call(99), object, 2, 'Factory'), first);
    expect(bridge.creations, hasLength(1));
    expect(bridge.byPointer.containsKey(99), isFalse);
    expect(
      bridge.api.ownerValue(bridge.env, Pointer.fromAddress(first), 'input', 2),
      same(object),
    );
  });

  test('cache uses object identity rather than equality', () {
    final first = _EqualValue();
    final second = _EqualValue();
    expect(first, second);
    expect(identical(first, second), isFalse);
    final left = bridge.api.referenceResult(bridge.env, first, 0, 'left');
    final right = bridge.api.referenceResult(bridge.env, second, 0, 'right');
    expect(left, isNot(right));
    expect(bridge.creations, hasLength(2));
  });

  test('late old-lease release cannot remove a replacement wrapper', () {
    final object = Object();
    var pointer = bridge.api.referenceResult(bridge.env, object, 1, 'initial');
    for (var i = 0; i < 20; i++) {
      final previousLease = bridge.byPointer[pointer]!;
      bridge.expire(previousLease);
      pointer = bridge.api.referenceResult(
        bridge.env,
        object,
        1,
        'replacement',
      );
      final replacementLease = bridge.byPointer[pointer]!;
      expect(replacementLease, greaterThan(previousLease));
      bridge.api.releaseOwner(previousLease);
      bridge.api.releaseOwner(previousLease);
      expect(
        bridge.api.ownerValue(
          bridge.env,
          Pointer.fromAddress(pointer),
          'use',
          1,
        ),
        same(object),
      );
      expect(
        bridge.api.referenceResult(bridge.env, object, 1, 'cached'),
        pointer,
      );
    }
    expect(bridge.creations, hasLength(21));
  });

  test('public class binding is sticky after cache expiry and release', () {
    final object = Object();
    bridge.api.wrap(bridge.call(99), object, 3, 'Counter');
    expect(
      () =>
          bridge.api.ownerValue(bridge.env, Pointer.fromAddress(99), 'arg', 4),
      throwsA(isA<NapiTypeError>()),
    );
    final lease = bridge.byPointer[99]!;
    bridge.expire(lease);
    bridge.api.releaseOwner(lease);
    expect(
      () => bridge.api.referenceResult(bridge.env, object, 4, 'different'),
      throwsA(
        isA<NapiTypeError>().having(
          (error) => error.message,
          'path',
          startsWith('different:'),
        ),
      ),
    );
    expect(
      bridge.api.referenceResult(bridge.env, object, 3, 'same class'),
      isPositive,
    );
  });

  test('failed attach/create rolls back retention and permits recovery', () {
    final object = Object();
    bridge.failWrap = true;
    expect(
      () => bridge.api.wrap(bridge.call(99), object, 1, 'bad attach'),
      throwsStateError,
    );
    final failedLease = bridge.lastLease;
    bridge.byPointer[99] = failedLease;
    expect(
      () => bridge.api.ownerValue(bridge.env, Pointer.fromAddress(99), 'lost'),
      throwsA(isA<NapiTypeError>()),
    );
    bridge.byPointer.remove(99);
    bridge.failCreate = true;
    expect(
      () => bridge.api.referenceResult(bridge.env, object, 1, 'bad create'),
      throwsStateError,
    );
    bridge.failWrap = false;
    bridge.failCreate = false;
    // A failed first attachment did not claim a public class for this object.
    final recovered = bridge.api.wrap(bridge.call(100), object, 2, 'recover');
    expect(recovered, 100);
    expect(
      bridge.api.ownerValue(bridge.env, Pointer.fromAddress(100), 'use', 2),
      same(object),
    );
  });

  test('foreign handles and the old table are rejected before use', () {
    expect(
      () =>
          bridge.api.ownerValue(bridge.env, Pointer.fromAddress(500), 'input'),
      throwsA(
        isA<NapiTypeError>().having(
          (error) => error.message,
          'path',
          startsWith('input:'),
        ),
      ),
    );
    expect(() => NapiApi(bridge.table.address, 28), throwsStateError);
    expect(() => NapiApi(bridge.table.address, 30), throwsStateError);
  });
}
