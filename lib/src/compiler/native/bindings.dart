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

/// Private synchronous Node-API table used by generated AOT entrypoints.
/// Every temporary native buffer is scoped to one call; no global scratch state.
final class NapiApi {
  final Pointer<Pointer<Void>> _table;
  NapiApi(int address, int tableCount) : _table = Pointer.fromAddress(address) {
    if (address == 0 || tableCount != 28) {
      throw StateError('Incompatible native bridge ABI (expected 28 slots).');
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
  final _owners = <int, Object>{};
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
    String path,
  ) {
    if (typeOf(env, value) != type) {
      throw NapiTypeError('$path: expected a JavaScript $name');
    }
  }

  int integer(Pointer<Void> env, Pointer<Void> value, String path) {
    final number = doubleValue(env, value, path);
    if (!number.isFinite ||
        number.truncateToDouble() != number ||
        number.abs() > 9007199254740991) {
      throw NapiRangeError('$path: expected a safe integer');
    }
    return number.toInt();
  }

  double doubleValue(Pointer<Void> env, Pointer<Void> value, String path) {
    _expect(env, value, 3, 'number', path);
    final out = _allocate<Double>(1, sizeOf<Double>());
    try {
      _check(_getDouble(env, value, out));
      return out.value;
    } finally {
      _free(out.cast());
    }
  }

  bool boolean(Pointer<Void> env, Pointer<Void> value, String path) {
    _expect(env, value, 2, 'boolean', path);
    final out = _allocate<Bool>(1, sizeOf<Bool>());
    try {
      _check(_getBool(env, value, out));
      return out.value;
    } finally {
      _free(out.cast());
    }
  }

  String string(Pointer<Void> env, Pointer<Void> value, String path) {
    _expect(env, value, 4, 'string', path);
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

  int integerBigInt(Pointer<Void> env, Pointer<Void> value, String path) {
    _expect(env, value, 9, 'bigint', path);
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

  BigInt bigInteger(Pointer<Void> env, Pointer<Void> value, String path) {
    _expect(env, value, 9, 'bigint', path);
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

  int wrap(NapiCall call, Object object) {
    final id = _nextOwner++;
    if (id <= 0) throw StateError('Native owner id exhausted');
    _owners[id] = object;
    try {
      _check(_wrap(call.env, call.self, id));
      return call.self.address;
    } catch (_) {
      _owners.remove(id);
      rethrow;
    }
  }

  Object owner(NapiCall call) {
    final id = _unwrap(call.env, call.self);
    if (id == 0) throw NapiTypeError('Invalid native receiver');
    final object = _owners[id];
    if (object == null) throw NapiTypeError('Native receiver was released');
    return object;
  }

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
