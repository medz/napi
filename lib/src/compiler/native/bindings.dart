import 'dart:convert';
import 'dart:ffi';

typedef _CallbackInfoNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Size>,
  Pointer<Pointer<Void>>,
  Pointer<Pointer<Void>>,
  Pointer<Pointer<Void>>,
);
typedef _CallbackInfo = int Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Size>,
  Pointer<Pointer<Void>>,
  Pointer<Pointer<Void>>,
  Pointer<Pointer<Void>>,
);
typedef _TypeNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Int32>,
);
typedef _Type = int Function(Pointer<Void>, Pointer<Void>, Pointer<Int32>);
typedef _GetDoubleNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Double>,
);
typedef _GetDouble = int Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Double>,
);
typedef _CreateDoubleNative = Int32 Function(
  Pointer<Void>,
  Double,
  Pointer<Pointer<Void>>,
);
typedef _CreateDouble = int Function(
  Pointer<Void>,
  double,
  Pointer<Pointer<Void>>,
);
typedef _GetBoolNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Bool>,
);
typedef _GetBool = int Function(Pointer<Void>, Pointer<Void>, Pointer<Bool>);
typedef _CreateBoolNative = Int32 Function(
  Pointer<Void>,
  Bool,
  Pointer<Pointer<Void>>,
);
typedef _CreateBool = int Function(Pointer<Void>, bool, Pointer<Pointer<Void>>);
typedef _SimpleNative = Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>);
typedef _Simple = int Function(Pointer<Void>, Pointer<Pointer<Void>>);
typedef _GetStringNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Uint16>,
  Size,
  Pointer<Size>,
);
typedef _GetString = int Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Uint16>,
  int,
  Pointer<Size>,
);
typedef _CreateStringNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint16>,
  Size,
  Pointer<Pointer<Void>>,
);
typedef _CreateString = int Function(
  Pointer<Void>,
  Pointer<Uint16>,
  int,
  Pointer<Pointer<Void>>,
);
typedef _NewTargetNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);
typedef _NewTarget = int Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);
typedef _WrapNative = Int32 Function(Pointer<Void>, Pointer<Void>, Int64);
typedef _Wrap = int Function(Pointer<Void>, Pointer<Void>, int);
typedef _UnwrapNative = Int64 Function(Pointer<Void>, Pointer<Void>);
typedef _Unwrap = int Function(Pointer<Void>, Pointer<Void>);
typedef _ReferenceValueNative = Int32 Function(
  Pointer<Void>,
  Int64,
  Pointer<Pointer<Void>>,
);
typedef _ReferenceValue = int Function(
  Pointer<Void>,
  int,
  Pointer<Pointer<Void>>,
);
typedef _ReferenceCreateNative = Int32 Function(
  Pointer<Void>,
  Uint32,
  Int64,
  Pointer<Pointer<Void>>,
);
typedef _ReferenceCreate = int Function(
  Pointer<Void>,
  int,
  int,
  Pointer<Pointer<Void>>,
);
typedef _InspectShapeNative = Int32 Function(
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
typedef _InspectShape = int Function(
  Pointer<Void>,
  Pointer<Void>,
  bool,
  Pointer<Pointer<Void>>,
  int,
  Pointer<Void>,
  int,
  int,
  bool,
  Pointer<Uint32>,
);
typedef _ReadOwnValueNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);
typedef _ReadOwnValue = int Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);
typedef _StrictEqualsNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Bool>,
);
typedef _StrictEquals = int Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Bool>,
);
typedef _CreateContainerNative = Int32 Function(
  Pointer<Void>,
  Bool,
  Uint32,
  Pointer<Pointer<Void>>,
);
typedef _CreateContainer = int Function(
  Pointer<Void>,
  bool,
  int,
  Pointer<Pointer<Void>>,
);
typedef _DefineOwnValueNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
);
typedef _DefineOwnValue = int Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
);
typedef _SnapshotMapNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Uint32,
  Uint32,
  Bool,
  Pointer<Pointer<Void>>,
  Pointer<Uint32>,
);
typedef _SnapshotMap = int Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  int,
  int,
  bool,
  Pointer<Pointer<Void>>,
  Pointer<Uint32>,
);
typedef _DictionaryKeysNative = _SnapshotMapNative;
typedef _DictionaryKeys = _SnapshotMap;
typedef _CheckedInsertMapNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
);
typedef _CheckedInsertMap = int Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
);
typedef _GetInt64Native = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Int64>,
  Pointer<Bool>,
);
typedef _GetInt64 = int Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Int64>,
  Pointer<Bool>,
);
typedef _CreateInt64Native = Int32 Function(
  Pointer<Void>,
  Int64,
  Pointer<Pointer<Void>>,
);
typedef _CreateInt64 = int Function(Pointer<Void>, int, Pointer<Pointer<Void>>);
typedef _GetWordsNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Int32>,
  Pointer<Size>,
  Pointer<Uint64>,
);
typedef _GetWords = int Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Int32>,
  Pointer<Size>,
  Pointer<Uint64>,
);
typedef _CreateWordsNative = Int32 Function(
  Pointer<Void>,
  Int32,
  Size,
  Pointer<Uint64>,
  Pointer<Pointer<Void>>,
);
typedef _CreateWords = int Function(
  Pointer<Void>,
  int,
  int,
  Pointer<Uint64>,
  Pointer<Pointer<Void>>,
);
typedef _CreateErrorNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);
typedef _CreateError = int Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);
typedef _ThrowNative = Int32 Function(Pointer<Void>, Pointer<Void>);
typedef _Throw = int Function(Pointer<Void>, Pointer<Void>);
typedef _PendingNative = Int32 Function(Pointer<Void>, Pointer<Bool>);
typedef _Pending = int Function(Pointer<Void>, Pointer<Bool>);
typedef _OptionsNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Bool,
  Pointer<Pointer<Uint8>>,
  Size,
  Pointer<Pointer<Void>>,
  Pointer<Uint8>,
  Pointer<Uint8>,
);
typedef _Options = int Function(
  Pointer<Void>,
  Pointer<Void>,
  bool,
  Pointer<Pointer<Uint8>>,
  int,
  Pointer<Pointer<Void>>,
  Pointer<Uint8>,
  Pointer<Uint8>,
);
typedef _CallocNative = Pointer<Void> Function(Size, Size);
typedef _Calloc = Pointer<Void> Function(int, int);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _Free = void Function(Pointer<Void>);

final _libc = DynamicLibrary.process();
final _calloc = _libc.lookupFunction<_CallocNative, _Calloc>('calloc');
final _free = _libc.lookupFunction<_FreeNative, _Free>('free');

Pointer<T> _allocate<T extends NativeType>(int count, int bytes) {
  final result = _calloc(count == 0 ? 1 : count, bytes);
  if (result == nullptr) throw StateError('Native allocation failed');
  return result.cast<T>();
}

Pointer<Uint8> _utf8(String value) {
  final bytes = utf8.encode(value);
  final result = _allocate<Uint8>(bytes.length + 1, 1);
  result.asTypedList(bytes.length).setAll(0, bytes);
  return result;
}

final class NapiTypeError implements Exception {
  final String message;
  NapiTypeError(this.message);
  @override
  String toString() => message;
}

final class NapiRangeError implements Exception {
  final String message;
  NapiRangeError(this.message);
  @override
  String toString() => message;
}

final class NapiCall {
  final Pointer<Void> env;
  final Pointer<Void> info;
  final Pointer<Void> self;
  final List<Pointer<Void>> arguments;
  final int argumentCount;
  NapiCall(this.env, this.info, this.self, this.arguments, this.argumentCount);
}

final class NapiOptions {
  final List<Pointer<Void>> values;
  final List<bool> present;
  NapiOptions(this.values, this.present);
}

final class _ReferenceLease {
  final int id;
  final int classId;
  const _ReferenceLease(this.id, this.classId);
}

/// Private synchronous Node-API table used by generated AOT entrypoints.
/// Every temporary native buffer is scoped to one call; no global scratch state.
final class NapiApi {
  final Pointer<Pointer<Void>> _table;
  NapiApi(int address, int tableCount) : _table = Pointer.fromAddress(address) {
    if (address == 0 || tableCount != 40) {
      throw StateError('Incompatible native bridge ABI (expected 40 slots).');
    }
  }
  late final _CallbackInfo _callbackInfo = _table[0]
      .cast<NativeFunction<_CallbackInfoNative>>()
      .asFunction<_CallbackInfo>();
  late final _Type _type = _table[1]
      .cast<NativeFunction<_TypeNative>>()
      .asFunction<_Type>();
  late final _GetDouble _getDouble = _table[2]
      .cast<NativeFunction<_GetDoubleNative>>()
      .asFunction<_GetDouble>();
  late final _CreateDouble _createDouble = _table[3]
      .cast<NativeFunction<_CreateDoubleNative>>()
      .asFunction<_CreateDouble>();
  late final _Simple _undefined = _table[6]
      .cast<NativeFunction<_SimpleNative>>()
      .asFunction<_Simple>();
  late final _Simple _null = _table[7]
      .cast<NativeFunction<_SimpleNative>>()
      .asFunction<_Simple>();
  late final _GetString _getString = _table[8]
      .cast<NativeFunction<_GetStringNative>>()
      .asFunction<_GetString>();
  late final _CreateString _createString = _table[9]
      .cast<NativeFunction<_CreateStringNative>>()
      .asFunction<_CreateString>();
  late final _NewTarget _newTarget = _table[10]
      .cast<NativeFunction<_NewTargetNative>>()
      .asFunction<_NewTarget>();
  late final _Wrap _wrap = _table[14]
      .cast<NativeFunction<_WrapNative>>()
      .asFunction<_Wrap>();
  late final _Unwrap _unwrap = _table[15]
      .cast<NativeFunction<_UnwrapNative>>()
      .asFunction<_Unwrap>();
  late final _GetBool _getBool = _table[16]
      .cast<NativeFunction<_GetBoolNative>>()
      .asFunction<_GetBool>();
  late final _CreateBool _createBool = _table[17]
      .cast<NativeFunction<_CreateBoolNative>>()
      .asFunction<_CreateBool>();
  late final _GetInt64 _getInt64 = _table[18]
      .cast<NativeFunction<_GetInt64Native>>()
      .asFunction<_GetInt64>();
  late final _CreateInt64 _createInt64 = _table[19]
      .cast<NativeFunction<_CreateInt64Native>>()
      .asFunction<_CreateInt64>();
  late final _GetWords _getWords = _table[20]
      .cast<NativeFunction<_GetWordsNative>>()
      .asFunction<_GetWords>();
  late final _CreateWords _createWords = _table[21]
      .cast<NativeFunction<_CreateWordsNative>>()
      .asFunction<_CreateWords>();
  late final _CreateError _createError = _table[22]
      .cast<NativeFunction<_CreateErrorNative>>()
      .asFunction<_CreateError>();
  late final _CreateError _createTypeError = _table[23]
      .cast<NativeFunction<_CreateErrorNative>>()
      .asFunction<_CreateError>();
  late final _CreateError _createRangeError = _table[24]
      .cast<NativeFunction<_CreateErrorNative>>()
      .asFunction<_CreateError>();
  late final _Throw _throw = _table[25]
      .cast<NativeFunction<_ThrowNative>>()
      .asFunction<_Throw>();
  late final _Pending _pending = _table[26]
      .cast<NativeFunction<_PendingNative>>()
      .asFunction<_Pending>();
  late final _Options _options = _table[27]
      .cast<NativeFunction<_OptionsNative>>()
      .asFunction<_Options>();
  late final _ReferenceValue _referenceValue = _table[28]
      .cast<NativeFunction<_ReferenceValueNative>>()
      .asFunction<_ReferenceValue>();
  late final _ReferenceCreate _referenceCreate = _table[29]
      .cast<NativeFunction<_ReferenceCreateNative>>()
      .asFunction<_ReferenceCreate>();
  late final _InspectShape _inspectShape = _table[30]
      .cast<NativeFunction<_InspectShapeNative>>()
      .asFunction<_InspectShape>();
  late final _ReadOwnValue _readOwnValue = _table[31]
      .cast<NativeFunction<_ReadOwnValueNative>>()
      .asFunction<_ReadOwnValue>();
  late final _StrictEquals _strictEquals = _table[32]
      .cast<NativeFunction<_StrictEqualsNative>>()
      .asFunction<_StrictEquals>();
  late final _CreateContainer _createContainer = _table[33]
      .cast<NativeFunction<_CreateContainerNative>>()
      .asFunction<_CreateContainer>();
  late final _DefineOwnValue _defineOwnValue = _table[34]
      .cast<NativeFunction<_DefineOwnValueNative>>()
      .asFunction<_DefineOwnValue>();
  late final _SnapshotMap _snapshotMap = _table[35]
      .cast<NativeFunction<_SnapshotMapNative>>()
      .asFunction<_SnapshotMap>();
  late final _Simple _createMap = _table[36]
      .cast<NativeFunction<_SimpleNative>>()
      .asFunction<_Simple>();
  late final _CheckedInsertMap _checkedInsertMap = _table[37]
      .cast<NativeFunction<_CheckedInsertMapNative>>()
      .asFunction<_CheckedInsertMap>();
  late final _DictionaryKeys _dictionaryKeys = _table[38]
      .cast<NativeFunction<_DictionaryKeysNative>>()
      .asFunction<_DictionaryKeys>();
  late final _Simple _createDictionary = _table[39]
      .cast<NativeFunction<_SimpleNative>>()
      .asFunction<_Simple>();
  // Only an attached JS lease retains its Dart value. The identity cache's
  // weak keys and primitive records cannot keep either heap alive by themselves.
  final _owners = <int, Object>{};
  final _references = Expando<_ReferenceLease>('native reference lease');
  var _nextOwner = 1;

  void _check(int status) {
    if (status != 0) throw StateError('Node-API operation failed ($status)');
  }

  int _result(int Function(Pointer<Pointer<Void>>) create) {
    final out = _allocate<Pointer<Void>>(1, sizeOf<Pointer<Void>>());
    try {
      _check(create(out));
      return out.value.address;
    } finally {
      _free(out.cast());
    }
  }

  NapiCall call(int envAddress, int infoAddress, int capacity) {
    final env = Pointer<Void>.fromAddress(envAddress);
    final info = Pointer<Void>.fromAddress(infoAddress);
    Pointer<Size> count = nullptr;
    Pointer<Pointer<Void>> arguments = nullptr;
    Pointer<Pointer<Void>> self = nullptr;
    try {
      count = _allocate<Size>(1, sizeOf<Size>());
      arguments = _allocate<Pointer<Void>>(capacity, sizeOf<Pointer<Void>>());
      self = _allocate<Pointer<Void>>(1, sizeOf<Pointer<Void>>());
      count.value = 0;
      _check(_callbackInfo(env, info, count, nullptr, self, nullptr));
      final actual = count.value;
      count.value = capacity;
      _check(_callbackInfo(env, info, count, arguments, self, nullptr));
      return NapiCall(env, info, self.value, [
        for (var i = 0; i < capacity; i++) arguments[i],
      ], actual);
    } finally {
      _free(self.cast());
      _free(arguments.cast());
      _free(count.cast());
    }
  }

  int typeOf(Pointer<Void> env, Pointer<Void> value) {
    final out = _allocate<Int32>(1, sizeOf<Int32>());
    try {
      _check(_type(env, value, out));
      return out.value;
    } finally {
      _free(out.cast());
    }
  }

  bool omittedOrUndefined(NapiCall call, int index) =>
      index >= call.argumentCount ||
      typeOf(call.env, call.arguments[index]) == 0;
  bool isNull(Pointer<Void> env, Pointer<Void> value) =>
      typeOf(env, value) == 1;
  Pointer<Void> requiredArgument(NapiCall call, int index, String path) {
    if (omittedOrUndefined(call, index)) {
      throw NapiTypeError('$path: missing required argument');
    }
    return call.arguments[index];
  }

  Pointer<Void> requiredOption(
    Pointer<Void> env,
    NapiOptions options,
    int index,
    String path,
  ) {
    if (!options.present[index] || typeOf(env, options.values[index]) == 0) {
      throw NapiTypeError('$path: missing required argument');
    }
    return options.values[index];
  }

  bool defaultOption(Pointer<Void> env, NapiOptions options, int index) =>
      !options.present[index] || typeOf(env, options.values[index]) == 0;

  NapiOptions options(
    NapiCall call,
    int position,
    List<String> names,
    String context,
  ) {
    Pointer<Pointer<Uint8>> keys = nullptr;
    Pointer<Pointer<Void>> values = nullptr;
    Pointer<Uint8> present = nullptr;
    Pointer<Uint8> path = nullptr;
    try {
      keys = _allocate<Pointer<Uint8>>(names.length, sizeOf<Pointer<Uint8>>());
      values = _allocate<Pointer<Void>>(names.length, sizeOf<Pointer<Void>>());
      present = _allocate<Uint8>(names.length, 1);
      path = _utf8(context);
      for (var i = 0; i < names.length; i++) {
        keys[i] = _utf8(names[i]);
      }
      final supplied = position < call.argumentCount;
      _check(
        _options(
          call.env,
          supplied ? call.arguments[position] : nullptr,
          supplied,
          keys,
          names.length,
          values,
          present,
          path,
        ),
      );
      return NapiOptions(
        [for (var i = 0; i < names.length; i++) values[i]],
        [for (var i = 0; i < names.length; i++) present[i] != 0],
      );
    } finally {
      if (keys != nullptr) {
        for (var i = 0; i < names.length; i++) {
          if (keys[i] != nullptr) _free(keys[i].cast());
        }
      }
      _free(path.cast());
      _free(present.cast());
      _free(values.cast());
      _free(keys.cast());
    }
  }

  void _expect(
    Pointer<Void> env,
    Pointer<Void> value,
    int type,
    String name,
    String path, {
    bool nullable = false,
  }) {
    if (typeOf(env, value) != type) {
      throw NapiTypeError(
        '$path: expected a JavaScript $name${nullable ? ' or null' : ''}',
      );
    }
  }

  int integer(
    Pointer<Void> env,
    Pointer<Void> value,
    String path, {
    bool nullable = false,
  }) {
    final number = doubleValue(env, value, path, nullable: nullable);
    if (!number.isFinite ||
        number.truncateToDouble() != number ||
        number.abs() > 9007199254740991) {
      throw NapiRangeError('$path: expected a safe integer');
    }
    return number.toInt();
  }

  double doubleValue(
    Pointer<Void> env,
    Pointer<Void> value,
    String path, {
    bool nullable = false,
  }) {
    _expect(env, value, 3, 'number', path, nullable: nullable);
    final out = _allocate<Double>(1, sizeOf<Double>());
    try {
      _check(_getDouble(env, value, out));
      return out.value;
    } finally {
      _free(out.cast());
    }
  }

  bool boolean(
    Pointer<Void> env,
    Pointer<Void> value,
    String path, {
    bool nullable = false,
  }) {
    _expect(env, value, 2, 'boolean', path, nullable: nullable);
    final out = _allocate<Bool>(1, sizeOf<Bool>());
    try {
      _check(_getBool(env, value, out));
      return out.value;
    } finally {
      _free(out.cast());
    }
  }

  String string(
    Pointer<Void> env,
    Pointer<Void> value,
    String path, {
    bool nullable = false,
  }) {
    _expect(env, value, 4, 'string', path, nullable: nullable);
    final length = _allocate<Size>(1, sizeOf<Size>());
    try {
      _check(_getString(env, value, nullptr, 0, length));
      final capacity = length.value + 1;
      final buffer = _allocate<Uint16>(capacity, sizeOf<Uint16>());
      try {
        _check(_getString(env, value, buffer, capacity, length));
        return String.fromCharCodes(buffer.asTypedList(length.value));
      } finally {
        _free(buffer.cast());
      }
    } finally {
      _free(length.cast());
    }
  }

  int integerBigInt(
    Pointer<Void> env,
    Pointer<Void> value,
    String path, {
    bool nullable = false,
  }) {
    _expect(env, value, 9, 'bigint', path, nullable: nullable);
    Pointer<Int64> out = nullptr;
    Pointer<Bool> lossless = nullptr;
    try {
      out = _allocate<Int64>(1, sizeOf<Int64>());
      lossless = _allocate<Bool>(1, sizeOf<Bool>());
      _check(_getInt64(env, value, out, lossless));
      if (!lossless.value) {
        throw NapiRangeError('$path: expected a signed 64-bit Dart int');
      }
      return out.value;
    } finally {
      _free(lossless.cast());
      _free(out.cast());
    }
  }

  BigInt bigInteger(
    Pointer<Void> env,
    Pointer<Void> value,
    String path, {
    bool nullable = false,
  }) {
    _expect(env, value, 9, 'bigint', path, nullable: nullable);
    Pointer<Size> count = nullptr;
    Pointer<Int32> sign = nullptr;
    try {
      count = _allocate<Size>(1, sizeOf<Size>());
      sign = _allocate<Int32>(1, sizeOf<Int32>());
      _check(_getWords(env, value, nullptr, count, nullptr));
      final words = _allocate<Uint64>(count.value, sizeOf<Uint64>());
      try {
        _check(_getWords(env, value, sign, count, words));
        var result = BigInt.zero;
        for (var i = count.value - 1; i >= 0; i--) {
          final word = words[i];
          result =
              (result << 64) |
              (BigInt.from((word >> 32) & 0xffffffff) << 32) |
              BigInt.from(word & 0xffffffff);
        }
        return sign.value == 0 ? result : -result;
      } finally {
        _free(words.cast());
      }
    } finally {
      _free(sign.cast());
      _free(count.cast());
    }
  }

  int undefinedResult(Pointer<Void> env) =>
      _result((out) => _undefined(env, out));
  int nullResult(Pointer<Void> env) => _result((out) => _null(env, out));
  int integerResult(Pointer<Void> env, int value, String path) {
    if (value < -9007199254740991 || value > 9007199254740991) {
      throw NapiRangeError('$path: expected a safe integer');
    }
    return doubleResult(env, value.toDouble());
  }

  int doubleResult(Pointer<Void> env, double value) =>
      _result((out) => _createDouble(env, value, out));
  int booleanResult(Pointer<Void> env, bool value) =>
      _result((out) => _createBool(env, value, out));
  int stringResult(Pointer<Void> env, String value) {
    final units = value.codeUnits;
    final buffer = _allocate<Uint16>(units.length + 1, sizeOf<Uint16>());
    try {
      buffer.asTypedList(units.length).setAll(0, units);
      return _result((out) => _createString(env, buffer, units.length, out));
    } finally {
      _free(buffer.cast());
    }
  }

  int integerBigIntResult(Pointer<Void> env, int value) =>
      _result((out) => _createInt64(env, value, out));
  int bigIntegerResult(Pointer<Void> env, BigInt value) {
    var remaining = value.abs();
    final count = (remaining.bitLength + 63) ~/ 64;
    final words = _allocate<Uint64>(count, sizeOf<Uint64>());
    final mask = (BigInt.one << 64) - BigInt.one;
    try {
      for (var i = 0; i < count; i++) {
        words[i] = (remaining & mask).toSigned(64).toInt();
        remaining >>= 64;
      }
      return _result(
        (out) => _createWords(env, value.isNegative ? 1 : 0, count, words, out),
      );
    } finally {
      _free(words.cast());
    }
  }

  int inspectShape(
    Pointer<Void> env,
    Pointer<Void> input,
    bool array,
    List<String> fields,
    String path,
    int remaining,
    int depth,
    bool cyclic,
  ) {
    Pointer<Pointer<Void>> keys = nullptr;
    Pointer<Uint32> length = nullptr;
    try {
      keys = _allocate<Pointer<Void>>(fields.length, sizeOf<Pointer<Void>>());
      length = _allocate<Uint32>(1, sizeOf<Uint32>());
      for (var i = 0; i < fields.length; i++) {
        keys[i] = Pointer<Void>.fromAddress(stringResult(env, fields[i]));
      }
      final context = Pointer<Void>.fromAddress(stringResult(env, path));
      _check(
        _inspectShape(
          env,
          input,
          array,
          keys,
          fields.length,
          context,
          remaining,
          depth,
          cyclic,
          length,
        ),
      );
      return length.value;
    } finally {
      _free(length.cast());
      _free(keys.cast());
    }
  }

  Pointer<Void> readOwnValue(
    Pointer<Void> env,
    Pointer<Void> input,
    String key,
    String path,
  ) {
    final name = Pointer<Void>.fromAddress(stringResult(env, key));
    final context = Pointer<Void>.fromAddress(stringResult(env, path));
    return Pointer<Void>.fromAddress(
      _result((out) => _readOwnValue(env, input, name, context, out)),
    );
  }

  bool strictEquals(
    Pointer<Void> env,
    Pointer<Void> left,
    Pointer<Void> right,
  ) {
    final result = _allocate<Bool>(1, sizeOf<Bool>());
    try {
      _check(_strictEquals(env, left, right, result));
      return result.value;
    } finally {
      _free(result.cast());
    }
  }

  int createContainer(Pointer<Void> env, bool array, int length) =>
      _result((out) => _createContainer(env, array, length, out));

  (Pointer<Void>, int) snapshotMap(
    Pointer<Void> env,
    Pointer<Void> input,
    String path,
    int remaining,
    int depth,
    bool cyclic,
  ) {
    Pointer<Pointer<Void>> pairs = nullptr;
    Pointer<Uint32> count = nullptr;
    try {
      pairs = _allocate<Pointer<Void>>(1, sizeOf<Pointer<Void>>());
      count = _allocate<Uint32>(1, sizeOf<Uint32>());
      final context = Pointer<Void>.fromAddress(stringResult(env, path));
      _check(
        _snapshotMap(
          env,
          input,
          context,
          remaining,
          depth,
          cyclic,
          pairs,
          count,
        ),
      );
      return (pairs.value, count.value);
    } finally {
      _free(count.cast());
      _free(pairs.cast());
    }
  }

  int createMap(Pointer<Void> env) => _result((out) => _createMap(env, out));

  (Pointer<Void>, int) dictionaryKeys(
    Pointer<Void> env,
    Pointer<Void> input,
    String path,
    int remaining,
    int depth,
    bool cyclic,
  ) {
    Pointer<Pointer<Void>> keys = nullptr;
    Pointer<Uint32> count = nullptr;
    try {
      keys = _allocate<Pointer<Void>>(1, sizeOf<Pointer<Void>>());
      count = _allocate<Uint32>(1, sizeOf<Uint32>());
      final context = Pointer<Void>.fromAddress(stringResult(env, path));
      _check(
        _dictionaryKeys(
          env,
          input,
          context,
          remaining,
          depth,
          cyclic,
          keys,
          count,
        ),
      );
      return (keys.value, count.value);
    } finally {
      _free(count.cast());
      _free(keys.cast());
    }
  }

  int createDictionary(Pointer<Void> env) =>
      _result((out) => _createDictionary(env, out));

  void checkedInsertMap(
    Pointer<Void> env,
    int map,
    int key,
    int value,
    String keyPath,
  ) {
    final context = Pointer<Void>.fromAddress(stringResult(env, keyPath));
    _check(
      _checkedInsertMap(
        env,
        Pointer<Void>.fromAddress(map),
        Pointer<Void>.fromAddress(key),
        Pointer<Void>.fromAddress(value),
        context,
      ),
    );
  }

  void defineOwnValue(Pointer<Void> env, int container, String key, int value) {
    final name = Pointer<Void>.fromAddress(stringResult(env, key));
    _check(
      _defineOwnValue(
        env,
        Pointer<Void>.fromAddress(container),
        name,
        Pointer<Void>.fromAddress(value),
      ),
    );
  }

  void checkNew(NapiCall call, bool required, String context) {
    final out = _allocate<Pointer<Void>>(1, sizeOf<Pointer<Void>>());
    try {
      _check(_newTarget(call.env, call.info, out));
      if (required != (out.value != nullptr)) {
        throw NapiTypeError(
          '$context: ${required ? 'constructor requires new' : 'function is not a constructor'}',
        );
      }
    } finally {
      _free(out.cast());
    }
  }

  int wrap(NapiCall call, Object object, int classId, [String? path]) =>
      _intern(call.env, object, classId, path ?? 'Native constructor', call);

  int referenceResult(
    Pointer<Void> env,
    Object object,
    int classId,
    String path, [
    List<(Object, int)>? pending,
  ]) => _intern(env, object, classId, path, null, pending);

  // A failed structural result has not exposed its newly created wrappers.
  // Keep their owners until the ordinary finalizers run, but undo only claims
  // first created by this result and still attached to the same lease.
  void rollbackReferences(List<(Object, int)> pending) {
    for (final (object, id) in pending.reversed) {
      if (_references[object]?.id == id) _references[object] = null;
    }
  }

  int _intern(
    Pointer<Void> env,
    Object object,
    int classId,
    String path,
    NapiCall? call, [
    List<(Object, int)>? pending,
  ]) {
    final cached = _references[object];
    if (cached != null) {
      if (cached.classId != classId) {
        throw NapiTypeError(
          '$path: object is bound to a different public class',
        );
      }
      final existing = _result((out) => _referenceValue(env, cached.id, out));
      if (existing != 0) return existing;
    }
    final id = _nextOwner++;
    if (id <= 0) throw StateError('Native owner id exhausted');
    _owners[id] = object;
    try {
      final int result;
      if (call == null) {
        result = _result((out) => _referenceCreate(env, classId, id, out));
        if (result == 0) {
          throw StateError('Native reference creation failed');
        }
      } else {
        _check(_wrap(env, call.self, id));
        result = call.self.address;
      }
      if (cached == null) pending?.add((object, id));
      _references[object] = _ReferenceLease(id, classId);
      return result;
    } catch (_) {
      _owners.remove(id);
      rethrow;
    }
  }

  Object owner(NapiCall call) =>
      ownerValue(call.env, call.self, 'Native receiver');

  Object ownerValue(
    Pointer<Void> env,
    Pointer<Void> value,
    String path, [
    int? classId,
  ]) {
    final id = _unwrap(env, value);
    if (id == 0) throw NapiTypeError('$path: invalid native receiver');
    final object = _owners[id];
    if (object == null) {
      throw NapiTypeError('$path: native receiver was released');
    }
    final lease = _references[object];
    if (lease == null ||
        lease.id != id ||
        (classId != null && lease.classId != classId)) {
      throw NapiTypeError('$path: incompatible native class');
    }
    return object;
  }

  // Do not clear the Expando here: an older lease's finalizer may arrive after
  // a replacement has been attached. The weak key dies with the Dart object.
  void releaseOwner(int id) => _owners.remove(id);

  bool _hasPending(Pointer<Void> env) {
    final out = _allocate<Bool>(1, sizeOf<Bool>());
    try {
      _check(_pending(env, out));
      return out.value;
    } finally {
      _free(out.cast());
    }
  }

  int fail(int envAddress, Object error) {
    final env = Pointer<Void>.fromAddress(envAddress);
    if (_hasPending(env)) return 0;
    String message;
    try {
      message = error.toString();
    } catch (_) {
      message = 'Dart operation failed (error description unavailable)';
    }
    final text = Pointer<Void>.fromAddress(stringResult(env, message));
    final create = error is NapiRangeError
        ? _createRangeError
        : error is NapiTypeError
        ? _createTypeError
        : _createError;
    final exception = Pointer<Void>.fromAddress(
      _result((out) => create(env, nullptr, text, out)),
    );
    _check(_throw(env, exception));
    return 0;
  }
}
