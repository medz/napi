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
typedef _TypeN = Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Int32>);
typedef _InspectN = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Bool,
  Pointer<Pointer<Void>>,
  Size,
  Pointer<Void>,
  Uint32,
  Uint32,
  Bool,
  Pointer<Uint32>,
);
typedef _ReadN = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);
typedef _EqualN = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Bool>,
);
typedef _CreateN = Int32 Function(
  Pointer<Void>,
  Bool,
  Uint32,
  Pointer<Pointer<Void>>,
);
typedef _DefineN = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
);
typedef _DictionaryKeysN = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Uint32,
  Uint32,
  Bool,
  Pointer<Pointer<Void>>,
  Pointer<Uint32>,
);
typedef _DictionaryCreateN = Int32 Function(
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);

final _libc = DynamicLibrary.process();
final _calloc = _libc
    .lookupFunction<_CallocN, Pointer<Void> Function(int, int)>('calloc');
final _free = _libc.lookupFunction<_FreeN, void Function(Pointer<Void>)>(
  'free',
);

// This validates the real FFI call signatures and temporary string/field
// buffers. Generated Node conformance separately exercises reflection itself.
final class _Table {
  final table = _calloc(53, sizeOf<Pointer<Void>>()).cast<Pointer<Void>>();
  final env = Pointer<Void>.fromAddress(1);
  final strings = <int, String>{};
  final calls = <List<Object?>>[];
  var next = 1000;
  var failure = 0;
  late final NativeCallable<_StringN> string;
  late final NativeCallable<_TypeN> type;
  late final NativeCallable<_InspectN> inspect;
  late final NativeCallable<_ReadN> read;
  late final NativeCallable<_EqualN> equal;
  late final NativeCallable<_CreateN> create;
  late final NativeCallable<_DefineN> define;
  late final NativeCallable<_DictionaryKeysN> dictionaryKeys;
  late final NativeCallable<_DictionaryCreateN> createDictionary;
  late final NapiApi api;

  _Table() {
    if (table == nullptr) throw StateError('Cannot allocate FFI test table');
    string = NativeCallable<_StringN>.isolateLocal((
      Pointer<Void> env,
      Pointer<Uint16> units,
      int count,
      Pointer<Pointer<Void>> out,
    ) {
      final address = ++next;
      strings[address] = String.fromCharCodes(units.asTypedList(count));
      out.value = Pointer<Void>.fromAddress(address);
      return 0;
    }, exceptionalReturn: 1);
    type = NativeCallable<_TypeN>.isolateLocal((
      Pointer<Void> env,
      Pointer<Void> input,
      Pointer<Int32> out,
    ) {
      out.value = 5; // symbol: fails every supported strict scalar reader.
      return 0;
    }, exceptionalReturn: 1);
    inspect = NativeCallable<_InspectN>.isolateLocal((
      Pointer<Void> env,
      Pointer<Void> input,
      bool array,
      Pointer<Pointer<Void>> fields,
      int count,
      Pointer<Void> path,
      int remaining,
      int depth,
      bool cyclic,
      Pointer<Uint32> length,
    ) {
      calls.add([
        'inspect',
        input.address,
        array,
        [for (var i = 0; i < count; i++) strings[fields[i].address]],
        strings[path.address],
        remaining,
        depth,
        cyclic,
      ]);
      length.value = 3;
      return failure;
    }, exceptionalReturn: 1);
    read = NativeCallable<_ReadN>.isolateLocal((
      Pointer<Void> env,
      Pointer<Void> input,
      Pointer<Void> key,
      Pointer<Void> path,
      Pointer<Pointer<Void>> out,
    ) {
      calls.add([
        'read',
        input.address,
        strings[key.address],
        strings[path.address],
      ]);
      out.value = Pointer<Void>.fromAddress(811);
      return failure;
    }, exceptionalReturn: 1);
    equal = NativeCallable<_EqualN>.isolateLocal((
      Pointer<Void> env,
      Pointer<Void> left,
      Pointer<Void> right,
      Pointer<Bool> out,
    ) {
      // Two different handles intentionally represent the same JS object.
      out.value = left.address % 100 == right.address % 100;
      return failure;
    }, exceptionalReturn: 1);
    create = NativeCallable<_CreateN>.isolateLocal((
      Pointer<Void> env,
      bool array,
      int length,
      Pointer<Pointer<Void>> out,
    ) {
      calls.add(['create', array, length]);
      out.value = Pointer<Void>.fromAddress(812);
      return failure;
    }, exceptionalReturn: 1);
    define = NativeCallable<_DefineN>.isolateLocal((
      Pointer<Void> env,
      Pointer<Void> target,
      Pointer<Void> key,
      Pointer<Void> value,
    ) {
      calls.add([
        'define',
        target.address,
        strings[key.address],
        value.address,
      ]);
      return failure;
    }, exceptionalReturn: 1);
    dictionaryKeys = NativeCallable<_DictionaryKeysN>.isolateLocal((
      Pointer<Void> env,
      Pointer<Void> input,
      Pointer<Void> path,
      int remaining,
      int depth,
      bool cyclic,
      Pointer<Pointer<Void>> keys,
      Pointer<Uint32> count,
    ) {
      calls.add([
        'dictionaryKeys',
        env.address,
        input.address,
        strings[path.address],
        remaining,
        depth,
        cyclic,
      ]);
      keys.value = Pointer<Void>.fromAddress(813);
      count.value = 2;
      return failure;
    }, exceptionalReturn: 1);
    createDictionary = NativeCallable<_DictionaryCreateN>.isolateLocal((
      Pointer<Void> env,
      Pointer<Pointer<Void>> out,
    ) {
      calls.add(['createDictionary', env.address]);
      out.value = Pointer<Void>.fromAddress(814);
      return failure;
    }, exceptionalReturn: 1);
    table[1] = type.nativeFunction.cast();
    table[9] = string.nativeFunction.cast();
    table[30] = inspect.nativeFunction.cast();
    table[31] = read.nativeFunction.cast();
    table[32] = equal.nativeFunction.cast();
    table[33] = create.nativeFunction.cast();
    table[34] = define.nativeFunction.cast();
    table[38] = dictionaryKeys.nativeFunction.cast();
    table[39] = createDictionary.nativeFunction.cast();
    api = NapiApi(table.address, 53);
  }

  void close() {
    createDictionary.close();
    dictionaryKeys.close();
    define.close();
    create.close();
    equal.close();
    read.close();
    inspect.close();
    type.close();
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
  final input = Pointer<Void>.fromAddress(11);
  const path = 'echo.\uD800\u0000value';

  test('shape FFI preserves fields, UTF-16 paths and policy arguments', () {
    expect(
      bridge.api.inspectShape(
        bridge.env,
        input,
        false,
        [r'$1', 'label'],
        path,
        9998,
        7,
        false,
      ),
      3,
    );
    expect(bridge.calls.single, [
      'inspect',
      11,
      false,
      [r'$1', 'label'],
      path,
      9998,
      7,
      false,
    ]);
    bridge.calls.clear();
    bridge.api.inspectShape(
      bridge.env,
      input,
      true,
      const [],
      path,
      0,
      64,
      true,
    );
    expect(bridge.calls.single, ['inspect', 11, true, [], path, 0, 64, true]);
  });

  test('own reads pass exact keys and child paths without string coercion', () {
    const key = '\uDC00\u0000key';
    final value = bridge.api.readOwnValue(bridge.env, input, key, path);
    expect(value.address, 811);
    expect(bridge.calls.single, ['read', 11, key, path]);
  });

  test('strict comparison uses the engine instead of handle addresses', () {
    expect(
      bridge.api.strictEquals(
        bridge.env,
        Pointer.fromAddress(11),
        Pointer.fromAddress(111),
      ),
      isTrue,
    );
    expect(
      bridge.api.strictEquals(
        bridge.env,
        Pointer.fromAddress(11),
        Pointer.fromAddress(112),
      ),
      isFalse,
    );
  });

  test('container creation and own definition preserve handles and keys', () {
    expect(bridge.api.createContainer(bridge.env, true, 2), 812);
    expect(bridge.calls.last, ['create', true, 2]);
    bridge.api.defineOwnValue(bridge.env, 812, '0', 811);
    expect(bridge.calls.last, ['define', 812, '0', 811]);
    bridge.api.createContainer(bridge.env, false, 0);
    bridge.api.defineOwnValue(bridge.env, 812, '__proto__\u0000\uD800', 811);
    expect(bridge.calls.last, ['define', 812, '__proto__\u0000\uD800', 811]);
  });

  test('non-ok inspection/read status stops conversion and recovers', () {
    bridge.failure = 10;
    expect(
      () => bridge.api.inspectShape(
        bridge.env,
        input,
        true,
        const [],
        path,
        9999,
        0,
        false,
      ),
      throwsStateError,
    );
    expect(
      () => bridge.api.readOwnValue(bridge.env, input, '0', path),
      throwsStateError,
    );
    bridge.failure = 0;
    expect(
      bridge.api.inspectShape(
        bridge.env,
        input,
        true,
        const [],
        path,
        9999,
        0,
        false,
      ),
      3,
    );
    expect(bridge.api.readOwnValue(bridge.env, input, '0', path).address, 811);
  });

  test(
    'Dictionary FFI snapshots only keys with exact bounds and UTF-16 paths',
    () {
      final (keys, count) = bridge.api.dictionaryKeys(
        bridge.env,
        input,
        path,
        9999,
        7,
        true,
      );
      expect(keys.address, 813);
      expect(count, 2);
      expect(bridge.calls.single, [
        'dictionaryKeys',
        1,
        11,
        path,
        9999,
        7,
        true,
      ]);
      // Child descriptors remain a separate operation on the original input.
      bridge.api.readOwnValue(bridge.env, input, '__proto__', path);
      expect(bridge.calls.last, ['read', 11, '__proto__', path]);
    },
  );

  test('Dictionary creation composes with safe own data definitions', () {
    expect(bridge.api.createDictionary(bridge.env), 814);
    expect(bridge.calls.last, ['createDictionary', 1]);
    bridge.api.defineOwnValue(bridge.env, 814, '__proto__\u0000\uD800', 811);
    expect(bridge.calls.last, ['define', 814, '__proto__\u0000\uD800', 811]);
  });

  test('failed Dictionary FFI operations stop and leave the API usable', () {
    bridge.failure = 10;
    expect(
      () => bridge.api.dictionaryKeys(bridge.env, input, path, 0, 64, false),
      throwsStateError,
    );
    expect(() => bridge.api.createDictionary(bridge.env), throwsStateError);
    bridge.failure = 0;
    expect(
      bridge.api.dictionaryKeys(bridge.env, input, path, 9999, 0, false).$2,
      2,
    );
    expect(bridge.api.createDictionary(bridge.env), 814);
  });

  test('nullable scalar leaves retain their shared strict error messages', () {
    final readers = <(String, void Function())>[
      (
        'number',
        () => bridge.api.integer(bridge.env, input, path, nullable: true),
      ),
      (
        'number',
        () => bridge.api.doubleValue(bridge.env, input, path, nullable: true),
      ),
      (
        'boolean',
        () => bridge.api.boolean(bridge.env, input, path, nullable: true),
      ),
      (
        'string',
        () => bridge.api.string(bridge.env, input, path, nullable: true),
      ),
      (
        'bigint',
        () => bridge.api.integerBigInt(bridge.env, input, path, nullable: true),
      ),
      (
        'bigint',
        () => bridge.api.bigInteger(bridge.env, input, path, nullable: true),
      ),
    ];
    for (final (kind, operation) in readers) {
      expect(
        operation,
        throwsA(
          isA<NapiTypeError>().having(
            (error) => error.message,
            'message',
            '$path: expected a JavaScript $kind or null',
          ),
        ),
      );
    }
  });
}
