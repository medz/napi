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
typedef _Target = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Uint32,
  Pointer<Bool>,
);
typedef _Create = Int32 Function(
  Pointer<Void>,
  Uint32,
  Int64,
  Pointer<Pointer<Void>>,
);
typedef _String = Int32 Function(
  Pointer<Void>,
  Pointer<Uint16>,
  Size,
  Pointer<Pointer<Void>>,
);
typedef _Register = Int32 Function(
  Pointer<Void>,
  Uint32,
  Pointer<Uint32>,
  Size,
  Pointer<Void>,
);

final _libc = DynamicLibrary.process();
final _calloc = _libc.lookupFunction<_CallocNative, _Calloc>('calloc');
final _free = _libc.lookupFunction<_FreeNative, _Free>('free');

// Test the Dart lease protocol through actual FFI calls. These callbacks model
// cache expiry/finalizer ordering; real Node weak references and teardown are
// covered by the generated native integration contract.
final class _Table {
  final table = _calloc(43, sizeOf<Pointer<Void>>()).cast<Pointer<Void>>();
  final byLease = <int, int>{};
  final byPointer = <int, int>{};
  final creations = <(int, int)>[];
  final registrations = <(int, List<int>, String)>[];
  final strings = <int, String>{};
  var nextPointer = 1000;
  var lastLease = 0;
  var failWrap = false;
  var failCreate = false;
  var failRegistration = false;
  var originalConstructorTarget = true;
  var targetChecks = 0;
  late final NativeCallable<_Target> target;
  late final NativeCallable<_Wrap> wrap;
  late final NativeCallable<_Unwrap> unwrap;
  late final NativeCallable<_Value> value;
  late final NativeCallable<_Create> create;
  late final NativeCallable<_String> string;
  late final NativeCallable<_Register> register;
  late final NapiApi api;
  final env = Pointer<Void>.fromAddress(1);

  _Table({
    int Function(Object, String)? referenceClass,
    List<int> Function(Object)? referenceViews,
    List<Set<int>> classMemberships = const [],
  }) {
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
    target = NativeCallable<_Target>.isolateLocal((
      Pointer<Void> env,
      Pointer<Void> info,
      int classId,
      Pointer<Bool> out,
    ) {
      targetChecks++;
      out.value = originalConstructorTarget;
      return 0;
    }, exceptionalReturn: 1);
    string = NativeCallable<_String>.isolateLocal((
      Pointer<Void> env,
      Pointer<Uint16> data,
      int length,
      Pointer<Pointer<Void>> out,
    ) {
      final pointer = ++nextPointer;
      strings[pointer] = String.fromCharCodes([
        for (var i = 0; i < length; i++) data[i],
      ]);
      out.value = Pointer.fromAddress(pointer);
      return 0;
    }, exceptionalReturn: 1);
    register = NativeCallable<_Register>.isolateLocal((
      Pointer<Void> env,
      int shape,
      Pointer<Uint32> views,
      int count,
      Pointer<Void> context,
    ) {
      registrations.add((
        shape,
        [for (var i = 0; i < count; i++) views[i]],
        strings[context.address]!,
      ));
      return failRegistration ? 1 : 0;
    }, exceptionalReturn: 1);
    table[9] = string.nativeFunction.cast();
    table[42] = register.nativeFunction.cast();
    table[41] = target.nativeFunction.cast();
    table[14] = wrap.nativeFunction.cast();
    table[15] = unwrap.nativeFunction.cast();
    table[28] = value.nativeFunction.cast();
    table[29] = create.nativeFunction.cast();
    api = NapiApi(
      table.address,
      43,
      referenceClass: referenceClass,
      referenceViews: referenceViews,
      classMemberships: classMemberships,
    );
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
    register.close();
    string.close();
    target.close();
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

class _Base {}

class _Child extends _Base {}

int _shape(Object object, String path) => object is _Child ? 1 : 0;

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

  test(
    'first Base exposure uses canonical Child and both receiver memberships',
    () {
      final table = _Table(
        referenceClass: _shape,
        classMemberships: const [
          {0},
          {0, 1},
        ],
      );
      addTearDown(table.close);
      final object = _Child();
      final pointer = table.api.referenceResult(table.env, object, 0, 'Base');
      expect(table.creations.single.$1, 1);
      expect(
        table.api.ownerValue(
          table.env,
          Pointer.fromAddress(pointer),
          'base receiver',
          0,
        ),
        same(object),
      );
      expect(
        table.api.ownerValue(
          table.env,
          Pointer.fromAddress(pointer),
          'child receiver',
          1,
        ),
        same(object),
      );
      expect(table.api.referenceResult(table.env, object, 1, 'Child'), pointer);
      final lease = table.byPointer[pointer]!;
      table.expire(lease);
      final pending = <(Object, int)>[];
      final replacement = table.api.referenceResult(
        table.env,
        object,
        0,
        'readopt',
        pending,
      );
      expect(pending, isEmpty);
      expect(table.creations.last.$1, 1);
      table.api.releaseOwner(lease);
      expect(
        table.api.ownerValue(
          table.env,
          Pointer.fromAddress(replacement),
          'replacement',
          0,
        ),
        same(object),
      );
    },
  );

  test('canonical adoption distinguishes original from custom new.target', () {
    final table = _Table(
      referenceClass: _shape,
      classMemberships: const [
        {0},
        {0, 1},
      ],
    );
    addTearDown(table.close);
    final original = table.api.wrap(
      table.call(90),
      _Child(),
      0,
      'Base factory',
    );
    expect(original, isNot(90));
    expect(table.creations.single.$1, 1);
    expect(table.targetChecks, 1);
    table.originalConstructorTarget = false;
    final object = _Child();
    expect(table.api.wrap(table.call(91), object, 0, 'custom target'), 91);
    expect(
      table.api.ownerValue(
        table.env,
        Pointer.fromAddress(91),
        'child method',
        1,
      ),
      same(object),
    );
    expect(table.api.wrap(table.call(92), object, 0, 'existing first'), 91);
    expect(table.targetChecks, 2);
    expect(table.byPointer.containsKey(92), isFalse);
  });

  test(
    'canonical rollback invalidates only the tentative lease then recovers',
    () {
      final table = _Table(
        referenceClass: _shape,
        classMemberships: const [
          {0},
          {0, 1},
        ],
      );
      addTearDown(table.close);
      final object = _Child();
      final pending = <(Object, int)>[];
      final tentative = table.api.referenceResult(
        table.env,
        object,
        0,
        'output',
        pending,
      );
      final lease = table.byPointer[tentative]!;
      table.api.rollbackReferences(pending);
      expect(
        () => table.api.ownerValue(
          table.env,
          Pointer.fromAddress(tentative),
          'unexposed',
          1,
        ),
        throwsA(isA<NapiTypeError>()),
      );
      final recovered = table.api.referenceResult(
        table.env,
        object,
        1,
        'recover',
      );
      expect(table.creations.last.$1, 1);
      table.api.rollbackReferences(pending);
      table.api.releaseOwner(lease);
      expect(
        table.api.ownerValue(
          table.env,
          Pointer.fromAddress(recovered),
          'base projection',
          0,
        ),
        same(object),
      );
    },
  );

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

  test('static classification never enters composite registration', () {
    final table = _Table(
      referenceClass: (_, _) => 0,
      referenceViews: (_) => throw StateError('must stay cold'),
      classMemberships: const [
        {0},
        {1},
      ],
    );
    addTearDown(table.close);
    table.api.referenceResult(table.env, Object(), 0, 'static');
    expect(table.registrations, isEmpty);
    expect(table.creations.single.$1, 0);
  });

  test(
    'composite shapes register sorted metadata once and accept every view',
    () {
      final table = _Table(
        referenceClass: (_, _) => -1,
        referenceViews: (_) => [1, 0, 1],
        classMemberships: const [
          {0},
          {1},
        ],
      );
      addTearDown(table.close);
      final object = Object();
      const path = 'result.\u0000\ud800';
      final first = table.api.referenceResult(table.env, object, 0, path);
      expect(table.api.referenceResult(table.env, object, 1, 'again'), first);
      table.api.referenceResult(table.env, Object(), 1, 'another object');
      expect(table.registrations, hasLength(1));
      expect(table.registrations.single.$1, 2);
      expect(table.registrations.single.$2, [0, 1]);
      expect(table.registrations.single.$3, path);
      expect(table.creations.map((entry) => entry.$1), [2, 2]);
      for (final view in [0, 1]) {
        expect(
          table.api.ownerValue(
            table.env,
            Pointer.fromAddress(first),
            'input',
            view,
          ),
          same(object),
        );
      }
    },
  );

  test('failed registration publishes no shape or lease and can retry', () {
    final table = _Table(
      referenceClass: (_, _) => -1,
      referenceViews: (_) => [0, 1],
      classMemberships: const [
        {0},
        {1},
      ],
    );
    addTearDown(table.close);
    final object = Object();
    table.failRegistration = true;
    expect(
      () => table.api.referenceResult(table.env, object, 0, 'bad'),
      throwsStateError,
    );
    expect(table.creations, isEmpty);
    table.failRegistration = false;
    final pointer = table.api.referenceResult(table.env, object, 1, 'valid');
    expect(table.registrations.map((entry) => entry.$1), [2, 2]);
    expect(table.creations.single.$1, 2);
    expect(
      table.api.ownerValue(table.env, Pointer.fromAddress(pointer), 'input', 0),
      same(object),
    );
  });

  test('composite new.target, expiry and rollback keep shared identity', () {
    final table = _Table(
      referenceClass: (_, _) => -1,
      referenceViews: (_) => [0, 1],
      classMemberships: const [
        {0},
        {1},
      ],
    );
    addTearDown(table.close);
    final original = table.api.wrap(table.call(90), Object(), 0, 'factory');
    expect(original, isNot(90));
    expect(table.creations.single.$1, 2);
    table.originalConstructorTarget = false;
    final customObject = Object();
    expect(table.api.wrap(table.call(91), customObject, 0, 'custom'), 91);
    expect(table.api.wrap(table.call(92), customObject, 1, 'existing'), 91);
    expect(table.targetChecks, 2);
    final object = Object();
    final pending = <(Object, int)>[];
    final tentative = table.api.referenceResult(
      table.env,
      object,
      0,
      'output',
      pending,
    );
    final oldLease = table.byPointer[tentative]!;
    table.api.rollbackReferences(pending);
    final replacement = table.api.referenceResult(
      table.env,
      object,
      1,
      'retry',
    );
    table.api.rollbackReferences(pending);
    table.api.releaseOwner(oldLease);
    final lease = table.byPointer[replacement]!;
    table.expire(lease);
    final readopted = table.api.referenceResult(
      table.env,
      object,
      0,
      'readopt',
    );
    table.api.releaseOwner(lease);
    expect(
      table.api.ownerValue(
        table.env,
        Pointer.fromAddress(readopted),
        'view',
        1,
      ),
      same(object),
    );
    expect(table.registrations, hasLength(1));
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

  test('unrelated schema-free class IDs stay rejected after cache expiry', () {
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
    expect(() => NapiApi(bridge.table.address, 35), throwsStateError);
    expect(() => NapiApi(bridge.table.address, 38), throwsStateError);
    expect(() => NapiApi(bridge.table.address, 41), throwsStateError);
    expect(() => NapiApi(bridge.table.address, 42), throwsStateError);
  });
}
