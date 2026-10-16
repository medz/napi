import 'dart:ffi';

import 'package:napi/src/compiler/native/bindings.dart';
import 'package:test/test.dart';

typedef _CallocNative = Pointer<Void> Function(Size, Size);
typedef _Calloc = Pointer<Void> Function(int, int);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _Free = void Function(Pointer<Void>);
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

// Model only the lease protocol through real FFI calls. Node weak-reference
// collection and failed structural output traversal have separate integration.
final class _LeaseBridge {
  final table = _calloc(38, sizeOf<Pointer<Void>>()).cast<Pointer<Void>>();
  final byLease = <int, int>{};
  final byPointer = <int, int>{};
  final creations = <(int, int)>[];
  final env = Pointer<Void>.fromAddress(1);
  var nextPointer = 1000;
  var lastLease = 0;
  var failCreate = false;
  late final NativeCallable<_Unwrap> unwrap;
  late final NativeCallable<_Value> value;
  late final NativeCallable<_Create> create;
  late final NapiApi api;

  _LeaseBridge() {
    if (table == nullptr) throw StateError('Cannot allocate test table');
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
    table[15] = unwrap.nativeFunction.cast();
    table[28] = value.nativeFunction.cast();
    table[29] = create.nativeFunction.cast();
    api = NapiApi(table.address, 38);
  }

  Object owner(int pointer, int classId) =>
      api.ownerValue(env, Pointer<Void>.fromAddress(pointer), 'input', classId);

  void expire(int lease) {
    final pointer = byLease.remove(lease);
    if (pointer != null) byPointer.remove(pointer);
  }

  void close() {
    create.close();
    value.close();
    unwrap.close();
    _free(table.cast());
  }
}

Matcher _nativeError(String message) => isA<NapiTypeError>().having(
  (error) => error.message,
  'message',
  contains(message),
);

void main() {
  late _LeaseBridge bridge;
  setUp(() {
    bridge = _LeaseBridge();
    addTearDown(bridge.close);
  });

  test('a failed output rolls back only its first public class claim', () {
    final object = Object();
    final pending = <(Object, int)>[];
    final first = bridge.api.referenceResult(
      bridge.env,
      object,
      0,
      'output[0]',
      pending,
    );
    final firstLease = bridge.byPointer[first]!;
    expect(pending, hasLength(1));
    expect(pending.single.$1, same(object));
    expect(pending.single.$2, firstLease);
    expect(
      bridge.api.referenceResult(bridge.env, object, 0, 'output[1]', pending),
      first,
    );
    expect(pending, hasLength(1));
    expect(
      () => bridge.api.referenceResult(
        bridge.env,
        object,
        1,
        'output[2]',
        pending,
      ),
      throwsA(_nativeError('different public class')),
    );
    bridge.api.rollbackReferences(pending);
    // A rollback removes the tentative class claim, while the JS token still
    // retains its Dart owner until that token's finalizer releases this lease.
    expect(
      () => bridge.owner(first, 0),
      throwsA(_nativeError('incompatible native class')),
    );
    final recovered = bridge.api.referenceResult(
      bridge.env,
      object,
      1,
      'recovered',
    );
    expect(recovered, isNot(first));
    expect(bridge.owner(recovered, 1), same(object));
    bridge.api.releaseOwner(firstLease);
    bridge.api.releaseOwner(firstLease);
    expect(
      () => bridge.owner(first, 0),
      throwsA(_nativeError('receiver was released')),
    );
    expect(bridge.owner(recovered, 1), same(object));
  });

  test('previous successful class claims survive another output rollback', () {
    final established = Object();
    final first = bridge.api.referenceResult(
      bridge.env,
      established,
      2,
      'successful',
    );
    final pending = <(Object, int)>[];
    expect(
      bridge.api.referenceResult(
        bridge.env,
        established,
        2,
        'output[0]',
        pending,
      ),
      first,
    );
    expect(pending, isEmpty);
    final tentative = Object();
    bridge.api.referenceResult(bridge.env, tentative, 0, 'output[1]', pending);
    expect(pending, hasLength(1));
    expect(pending.single.$1, same(tentative));
    bridge.api.rollbackReferences(pending);
    expect(bridge.owner(first, 2), same(established));
    expect(
      () => bridge.api.referenceResult(bridge.env, established, 3, 'conflict'),
      throwsA(_nativeError('different public class')),
    );
    expect(
      bridge.api.referenceResult(bridge.env, established, 2, 'cached'),
      first,
    );
  });

  test(
    'a replacement lease does not make an existing class claim tentative',
    () {
      final object = Object();
      final first = bridge.api.referenceResult(
        bridge.env,
        object,
        1,
        'success',
      );
      final oldLease = bridge.byPointer[first]!;
      bridge.expire(oldLease);
      final pending = <(Object, int)>[];
      final replacement = bridge.api.referenceResult(
        bridge.env,
        object,
        1,
        'replacement',
        pending,
      );
      expect(replacement, isNot(first));
      expect(pending, isEmpty);
      bridge.api.rollbackReferences(pending);
      bridge.api.releaseOwner(oldLease);
      expect(bridge.owner(replacement, 1), same(object));
      expect(
        () => bridge.api.referenceResult(bridge.env, object, 2, 'conflict'),
        throwsA(_nativeError('different public class')),
      );
    },
  );

  test(
    'an old rollback cannot clear a newer class claim for the same object',
    () {
      final object = Object();
      final pending = <(Object, int)>[];
      final first = bridge.api.referenceResult(
        bridge.env,
        object,
        0,
        'first',
        pending,
      );
      final oldPending = List<(Object, int)>.of(pending);
      bridge.api.rollbackReferences(pending);
      final current = bridge.api.referenceResult(
        bridge.env,
        object,
        1,
        'new claim',
      );
      expect(bridge.byPointer[current], isNot(bridge.byPointer[first]));
      bridge.api.rollbackReferences(oldPending);
      expect(bridge.owner(current, 1), same(object));
      expect(
        bridge.api.referenceResult(bridge.env, object, 1, 'cached'),
        current,
      );
      expect(
        () => bridge.api.referenceResult(bridge.env, object, 2, 'conflict'),
        throwsA(_nativeError('different public class')),
      );
    },
  );

  test('separate output queues cannot roll back another live input lease', () {
    final input = Object();
    final inputPointer = bridge.api.referenceResult(
      bridge.env,
      input,
      2,
      'input',
    );
    final failed = <(Object, int)>[];
    final successful = <(Object, int)>[];
    bridge.api.referenceResult(
      bridge.env,
      Object(),
      0,
      'failed output',
      failed,
    );
    final successfulObject = Object();
    final successfulPointer = bridge.api.referenceResult(
      bridge.env,
      successfulObject,
      1,
      'another output',
      successful,
    );
    bridge.api.rollbackReferences(failed);
    expect(bridge.owner(inputPointer, 2), same(input));
    expect(bridge.owner(successfulPointer, 1), same(successfulObject));
    expect(
      () => bridge.owner(inputPointer, 1),
      throwsA(_nativeError('incompatible native class')),
    );
    bridge.api.releaseOwner(failed.single.$2);
    expect(bridge.owner(inputPointer, 2), same(input));
    expect(bridge.owner(successfulPointer, 1), same(successfulObject));
  });

  test('failed native creation records no claim or retained Dart owner', () {
    final object = Object();
    final pending = <(Object, int)>[];
    bridge.failCreate = true;
    expect(
      () =>
          bridge.api.referenceResult(bridge.env, object, 0, 'failure', pending),
      throwsStateError,
    );
    expect(pending, isEmpty);
    bridge.byPointer[999] = bridge.lastLease;
    expect(
      () => bridge.owner(999, 0),
      throwsA(_nativeError('receiver was released')),
    );
    bridge.failCreate = false;
    final recovered = bridge.api.referenceResult(
      bridge.env,
      object,
      1,
      'recovered',
      pending,
    );
    expect(pending, hasLength(1));
    expect(bridge.owner(recovered, 1), same(object));
  });
}
