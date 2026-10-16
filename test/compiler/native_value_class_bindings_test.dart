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
typedef _ReadN = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);

void main() {
  final libc = DynamicLibrary.process();
  final calloc = libc
      .lookupFunction<_CallocN, Pointer<Void> Function(int, int)>('calloc');
  final free = libc.lookupFunction<_FreeN, void Function(Pointer<Void>)>(
    'free',
  );
  late Pointer<Pointer<Void>> table;
  late NativeCallable<_StringN> string;
  late NativeCallable<_TypeN> type;
  late NativeCallable<_ReadN> read;
  late NapiApi api;
  final env = Pointer<Void>.fromAddress(1);
  final input = Pointer<Void>.fromAddress(2);
  final strings = <int, String>{};
  final calls = <List<Object?>>[];
  var next = 100;
  var result = 0;
  var failure = 0;
  setUp(() {
    table = calloc(41, sizeOf<Pointer<Void>>()).cast();
    strings.clear();
    calls.clear();
    result = 0;
    failure = 0;
    string = NativeCallable<_StringN>.isolateLocal((
      Pointer<Void> env,
      Pointer<Uint16> text,
      int length,
      Pointer<Pointer<Void>> out,
    ) {
      final id = ++next;
      strings[id] = String.fromCharCodes(text.asTypedList(length));
      out.value = Pointer<Void>.fromAddress(id);
      return 0;
    }, exceptionalReturn: 1);
    type = NativeCallable<_TypeN>.isolateLocal((
      Pointer<Void> env,
      Pointer<Void> value,
      Pointer<Int32> out,
    ) {
      out.value = value.address == 201 ? 0 : 1;
      return 0;
    }, exceptionalReturn: 1);
    read = NativeCallable<_ReadN>.isolateLocal((
      Pointer<Void> env,
      Pointer<Void> value,
      Pointer<Void> key,
      Pointer<Void> path,
      Pointer<Pointer<Void>> out,
    ) {
      calls.add([
        env.address,
        value.address,
        strings[key.address],
        strings[path.address],
      ]);
      out.value = Pointer<Void>.fromAddress(result);
      return failure;
    }, exceptionalReturn: 1);
    table[1] = type.nativeFunction.cast();
    table[9] = string.nativeFunction.cast();
    table[40] = read.nativeFunction.cast();
    api = NapiApi(table.address, 41);
  });
  tearDown(() {
    read.close();
    type.close();
    string.close();
    free(table.cast());
  });

  test(
    'optional own read distinguishes missing, undefined and null handles',
    () {
      const key = '雪\u0000\ud800';
      const path = 'point.$key';
      expect(api.readOptionalOwnValue(env, input, key, path), nullptr);
      expect(calls.single, [1, 2, key, path]);
      result = 201;
      final undefined = api.readOptionalOwnValue(env, input, key, path);
      expect(undefined.address, 201);
      expect(api.isUndefined(env, undefined), isTrue);
      result = 202;
      final nullValue = api.readOptionalOwnValue(env, input, key, path);
      expect(nullValue.address, 202);
      expect(api.isUndefined(env, nullValue), isFalse);
      expect(calls, hasLength(3));
    },
  );

  test('failed reflection is not replaced by a missing default', () {
    failure = 10;
    expect(
      () => api.readOptionalOwnValue(env, input, 'x', 'point.x'),
      throwsStateError,
    );
    failure = 0;
    result = 203;
    expect(api.readOptionalOwnValue(env, input, 'x', 'point.x').address, 203);
  });

  test('ABI5 is rejected before any table access', () {
    expect(() => NapiApi(table.address, 40), throwsStateError);
  });
}
