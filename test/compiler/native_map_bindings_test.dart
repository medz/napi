import 'dart:ffi';

import 'package:napi/src/compiler/native/bindings.dart';
import 'package:test/test.dart';

typedef _CallocN = Pointer<Void> Function(Size, Size);
typedef _FreeN = Void Function(Pointer<Void>);
typedef _StringN = Int32 Function(
  Pointer<Void>,
  Pointer<Uint16>,
  Size,
  Pointer<Pointer<Void>>,
);
typedef _SnapshotN = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Uint32,
  Uint32,
  Bool,
  Pointer<Pointer<Void>>,
  Pointer<Uint32>,
);
typedef _CreateN = Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>);
typedef _InsertN = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
);

final _libc = DynamicLibrary.process();
final _calloc = _libc
    .lookupFunction<_CallocN, Pointer<Void> Function(int, int)>('calloc');
final _free = _libc.lookupFunction<_FreeN, void Function(Pointer<Void>)>(
  'free',
);

// Exercise actual FFI marshalling, including UTF-16 paths and both snapshot
// out-pointers. Map reflection/equality itself is covered by Node consumers.
final class _Table {
  final table = _calloc(46, sizeOf<Pointer<Void>>()).cast<Pointer<Void>>();
  final env = Pointer<Void>.fromAddress(1);
  final strings = <int, String>{};
  final calls = <List<Object?>>[];
  var next = 100;
  var failure = 0;
  late final NativeCallable<_StringN> string;
  late final NativeCallable<_SnapshotN> snapshot;
  late final NativeCallable<_CreateN> create;
  late final NativeCallable<_InsertN> insert;
  late final NapiApi api;

  _Table() {
    if (table == nullptr) throw StateError('Cannot allocate FFI test table');
    string = NativeCallable<_StringN>.isolateLocal((
      Pointer<Void> env,
      Pointer<Uint16> units,
      int length,
      Pointer<Pointer<Void>> out,
    ) {
      final address = ++next;
      strings[address] = String.fromCharCodes(units.asTypedList(length));
      out.value = Pointer<Void>.fromAddress(address);
      return 0;
    }, exceptionalReturn: 1);
    snapshot = NativeCallable<_SnapshotN>.isolateLocal((
      Pointer<Void> env,
      Pointer<Void> input,
      Pointer<Void> path,
      int remaining,
      int depth,
      bool cyclic,
      Pointer<Pointer<Void>> pairs,
      Pointer<Uint32> count,
    ) {
      calls.add([
        'snapshot',
        env.address,
        input.address,
        strings[path.address],
        remaining,
        depth,
        cyclic,
      ]);
      pairs.value = Pointer<Void>.fromAddress(2000);
      count.value = 3;
      return failure;
    }, exceptionalReturn: 1);
    create = NativeCallable<_CreateN>.isolateLocal((
      Pointer<Void> env,
      Pointer<Pointer<Void>> out,
    ) {
      calls.add(['create', env.address]);
      out.value = Pointer<Void>.fromAddress(3000);
      return failure;
    }, exceptionalReturn: 1);
    insert = NativeCallable<_InsertN>.isolateLocal((
      Pointer<Void> env,
      Pointer<Void> map,
      Pointer<Void> key,
      Pointer<Void> value,
      Pointer<Void> path,
    ) {
      calls.add([
        'insert',
        env.address,
        map.address,
        key.address,
        value.address,
        strings[path.address],
      ]);
      return failure;
    }, exceptionalReturn: 1);
    table[9] = string.nativeFunction.cast();
    table[35] = snapshot.nativeFunction.cast();
    table[36] = create.nativeFunction.cast();
    table[37] = insert.nativeFunction.cast();
    api = NapiApi(table.address, 46);
  }

  void close() {
    insert.close();
    create.close();
    snapshot.close();
    string.close();
    _free(table.cast());
  }
}

void main() {
  late _Table bridge;
  setUp(() {
    bridge = _Table();
    addTearDown(bridge.close);
  });

  test(
    'Map snapshot marshals bounds, cycles and both callback-scoped outputs',
    () {
      const path = 'input\u0000\ud800[2]';
      final result = bridge.api.snapshotMap(
        bridge.env,
        Pointer<Void>.fromAddress(42),
        path,
        9999,
        12,
        true,
      );
      expect(result.$1.address, 2000);
      expect(result.$2, 3);
      expect(bridge.calls.single, ['snapshot', 1, 42, path, 9999, 12, true]);
      bridge.failure = 1;
      expect(
        () => bridge.api.snapshotMap(
          bridge.env,
          Pointer<Void>.fromAddress(43),
          path,
          0,
          64,
          false,
        ),
        throwsStateError,
      );
      bridge.failure = 0;
      expect(
        bridge.api
            .snapshotMap(
              bridge.env,
              Pointer<Void>.fromAddress(44),
              path,
              9997,
              0,
              false,
            )
            .$2,
        3,
      );
    },
  );

  test(
    'Map construction and checked insert preserve handles and key paths',
    () {
      expect(bridge.api.createMap(bridge.env), 3000);
      const path = 'result[1].key\u0000\udfff';
      bridge.api.checkedInsertMap(bridge.env, 3000, 50, 51, path);
      expect(bridge.calls, [
        ['create', 1],
        ['insert', 1, 3000, 50, 51, path],
      ]);
      bridge.failure = 1;
      expect(
        () => bridge.api.checkedInsertMap(bridge.env, 3000, 52, 53, path),
        throwsStateError,
      );
      bridge.failure = 0;
      bridge.api.checkedInsertMap(bridge.env, 3000, 54, 55, path);
      expect(bridge.calls.last, ['insert', 1, 3000, 54, 55, path]);
    },
  );

  test('the Map ABI rejects earlier tables before accessing a slot', () {
    for (final count in [28, 30, 35, 38]) {
      expect(() => NapiApi(bridge.table.address, count), throwsStateError);
    }
    expect(() => NapiApi(0, 46), throwsStateError);
  });
}
