import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Platform;

typedef Js = Pointer<Void>;
typedef NapiCallback = Js Function(Js, Js);
typedef NapiThreadsafeCallback = Void Function(Js, Js, Js, Js);
typedef NapiFinalizer = Void Function(Js, Js, Js);
typedef _OutNative = Int32 Function(Js, Pointer<Js>);
typedef _ValueOutNative = Int32 Function(Js, Js, Pointer<Js>);
typedef _PairNative = Int32 Function(Js, Js, Js);

final _libc = Platform.isWindows
    ? DynamicLibrary.open('ucrtbase.dll')
    : DynamicLibrary.process();
final _calloc = _libc
    .lookupFunction<Js Function(UintPtr, UintPtr), Js Function(int, int)>(
      'calloc',
      isLeaf: true,
    );
final _free = _libc.lookupFunction<Void Function(Js), void Function(Js)>(
  'free',
  isLeaf: true,
);

@Native<_OutNative>(symbol: 'napi_get_undefined')
external int _undefined(Js env, Pointer<Js> output);

@Native<_OutNative>(symbol: 'napi_get_and_clear_last_exception')
external int _takeException(Js env, Pointer<Js> output);

@Native<_ValueOutNative>(symbol: 'napi_coerce_to_string')
external int _coerceString(Js env, Js value, Pointer<Js> output);

@Native<_PairNative>(symbol: 'napi_resolve_deferred')
external int _resolve(Js env, Js deferred, Js value);

@Native<_PairNative>(symbol: 'napi_reject_deferred')
external int _reject(Js env, Js deferred, Js value);

@Native<Int32 Function(Js, Pointer<Bool>)>(symbol: 'napi_is_exception_pending')
external int _pending(Js env, Pointer<Bool> output);

@Native<Int32 Function(Js, Js, Pointer<Int32>)>(symbol: 'napi_typeof')
external int _typeof(Js env, Js value, Pointer<Int32> output);

@Native<Int32 Function(Js, Js, Pointer<Double>)>(
  symbol: 'napi_get_value_double',
)
external int _readNumber(Js env, Js value, Pointer<Double> output);

@Native<Int32 Function(Js, Double, Pointer<Js>)>(symbol: 'napi_create_double')
external int _createNumber(Js env, double value, Pointer<Js> output);

@Native<Int32 Function(Js, Pointer<Uint16>, UintPtr, Pointer<Js>)>(
  symbol: 'napi_create_string_utf16',
)
external int _createString(
  Js env,
  Pointer<Uint16> value,
  int length,
  Pointer<Js> output,
);

@Native<Int32 Function(Js, Js, Pointer<Uint16>, UintPtr, Pointer<UintPtr>)>(
  symbol: 'napi_get_value_string_utf16',
)
external int _readString(
  Js env,
  Js value,
  Pointer<Uint16> buffer,
  int size,
  Pointer<UintPtr> length,
);

@Native<Int32 Function(Js, Js, Pointer<Char>, Js)>(
  symbol: 'napi_set_named_property',
)
external int _set(Js env, Js object, Pointer<Char> name, Js value);

@Native<
  Int32 Function(
    Js,
    Pointer<Char>,
    UintPtr,
    Pointer<NativeFunction<NapiCallback>>,
    Js,
    Pointer<Js>,
  )
>(symbol: 'napi_create_function')
external int _createFunction(
  Js env,
  Pointer<Char> name,
  int length,
  Pointer<NativeFunction<NapiCallback>> callback,
  Js data,
  Pointer<Js> output,
);

@Native<
  Int32 Function(
    Js,
    Js,
    Pointer<UintPtr>,
    Pointer<Js>,
    Pointer<Js>,
    Pointer<Js>,
  )
>(symbol: 'napi_get_cb_info')
external int _arguments(
  Js env,
  Js info,
  Pointer<UintPtr> count,
  Pointer<Js> arguments,
  Pointer<Js> receiver,
  Pointer<Js> data,
);

@Native<Int32 Function(Js, Pointer<Js>, Pointer<Js>)>(
  symbol: 'napi_create_promise',
)
external int _promise(Js env, Pointer<Js> deferred, Pointer<Js> output);

@Native<Int32 Function(Js, Js, Js, Pointer<Js>)>(symbol: 'napi_create_error')
external int _error(Js env, Js code, Js message, Pointer<Js> output);

@Native<Int32 Function(Js, Js)>(symbol: 'napi_throw')
external int _throwError(Js env, Js error);

@Native<Int32 Function(Js, Js, Js, Pointer<Js>)>(
  symbol: 'napi_create_type_error',
)
external int _typeError(Js env, Js code, Js message, Pointer<Js> output);

@Native<
  Int32 Function(
    Js,
    Js,
    Js,
    Js,
    UintPtr,
    UintPtr,
    Js,
    Pointer<NativeFunction<NapiFinalizer>>,
    Js,
    Pointer<NativeFunction<NapiThreadsafeCallback>>,
    Pointer<Js>,
  )
>(symbol: 'napi_create_threadsafe_function')
external int _createThreadsafe(
  Js env,
  Js function,
  Js resource,
  Js name,
  int queueSize,
  int threadCount,
  Js finalizerData,
  Pointer<NativeFunction<NapiFinalizer>> finalizer,
  Js context,
  Pointer<NativeFunction<NapiThreadsafeCallback>> callback,
  Pointer<Js> output,
);

@Native<Int32 Function(Js, Js)>(symbol: 'napi_ref_threadsafe_function')
external int _refThreadsafe(Js env, Js function);

@Native<Int32 Function(Js, Js)>(symbol: 'napi_unref_threadsafe_function')
external int _unrefThreadsafe(Js env, Js function);

@Native<Int32 Function(Js, Js, Int32)>(symbol: 'napi_call_threadsafe_function')
external int _callThreadsafe(Js function, Js data, int mode);

class _Scratch {
  final _allocations = <Js>[];

  Pointer<T> alloc<T extends NativeType>(int bytes) {
    final pointer = _calloc(1, bytes);
    if (pointer == nullptr) throw StateError('Native allocation failed');
    _allocations.add(pointer);
    return pointer.cast<T>();
  }

  Pointer<Char> utf8String(String value) {
    final bytes = utf8.encode(value);
    final pointer = alloc<Uint8>(bytes.length + 1);
    pointer.asTypedList(bytes.length).setAll(0, bytes);
    return pointer.cast();
  }

  void dispose() {
    for (final pointer in _allocations.reversed) {
      _free(pointer);
    }
  }
}

T _using<T>(T Function(_Scratch) body) {
  final scratch = _Scratch();
  try {
    return body(scratch);
  } finally {
    scratch.dispose();
  }
}

class CallbackArguments {
  final List<Js> values;
  CallbackArguments(this.values);
}

class NodeApi {
  final Js env;
  NodeApi(this.env);

  void _check(int status) {
    if (status == 0) return;
    var message = 'Node-API call failed (status $status)';
    _using((scratch) {
      final pending = scratch.alloc<Bool>(sizeOf<Bool>());
      if (_pending(env, pending) == 0 && pending.value) {
        final error = scratch.alloc<Js>(sizeOf<Js>());
        final value = scratch.alloc<Js>(sizeOf<Js>());
        if (_takeException(env, error) == 0 &&
            _coerceString(env, error.value, value) == 0) {
          final length = scratch.alloc<UintPtr>(sizeOf<UintPtr>());
          if (_readString(env, value.value, nullptr, 0, length) == 0) {
            final data = scratch.alloc<Uint16>((length.value + 1) * 2);
            if (_readString(env, value.value, data, length.value + 1, length) ==
                0) {
              message = String.fromCharCodes(data.asTypedList(length.value));
            }
          }
        }
        // A hostile thrown object's toString may itself throw.
        if (_pending(env, pending) == 0 && pending.value) {
          _takeException(env, error);
        }
      }
    });
    throw StateError(message);
  }

  Js _result(int Function(Pointer<Js>) operation) => _using((scratch) {
    final output = scratch.alloc<Js>(sizeOf<Js>());
    _check(operation(output));
    return output.value;
  });

  Js undefined() => _result((output) => _undefined(env, output));
  int type(Js value) => _using((scratch) {
    final output = scratch.alloc<Int32>(sizeOf<Int32>());
    _check(_typeof(env, value, output));
    return output.value;
  });
  double number(Js value) => _using((scratch) {
    final output = scratch.alloc<Double>(sizeOf<Double>());
    _check(_readNumber(env, value, output));
    return output.value;
  });
  Js numberValue(num value) =>
      _result((output) => _createNumber(env, value.toDouble(), output));

  Js string(String value) => _using((scratch) {
    final data = scratch.alloc<Uint16>((value.length + 1) * 2);
    data.asTypedList(value.length).setAll(0, value.codeUnits);
    return _result((output) => _createString(env, data, value.length, output));
  });

  String text(Js value) => _using((scratch) {
    final length = scratch.alloc<UintPtr>(sizeOf<UintPtr>());
    _check(_readString(env, value, nullptr, 0, length));
    final data = scratch.alloc<Uint16>((length.value + 1) * 2);
    _check(_readString(env, value, data, length.value + 1, length));
    return String.fromCharCodes(data.asTypedList(length.value));
  });

  void set(Js object, String name, Js value) => _using((scratch) {
    _check(_set(env, object, scratch.utf8String(name), value));
  });

  Js function(
    String name,
    Pointer<NativeFunction<NapiCallback>> callback,
    int dataToken,
  ) => _using((scratch) {
    final namePointer = scratch.utf8String(name);
    return _result(
      (output) => _createFunction(
        env,
        namePointer,
        utf8.encode(name).length,
        callback,
        Js.fromAddress(dataToken),
        output,
      ),
    );
  });

  CallbackArguments arguments(Js info) => _using((scratch) {
    final count = scratch.alloc<UintPtr>(sizeOf<UintPtr>())..value = 2;
    final values = scratch.alloc<Js>(2 * sizeOf<Js>());
    _check(_arguments(env, info, count, values, nullptr, nullptr));
    return CallbackArguments(
      List.generate(count.value.clamp(0, 2), (i) => values[i]),
    );
  });

  (Js, int) promise() => _using((scratch) {
    final deferred = scratch.alloc<Js>(sizeOf<Js>());
    final value = scratch.alloc<Js>(sizeOf<Js>());
    _check(_promise(env, deferred, value));
    return (value.value, deferred.value.address);
  });
  void resolve(int deferred, Js value) {
    _check(_resolve(env, Js.fromAddress(deferred), value));
  }

  void reject(int deferred, Js value) {
    _check(_reject(env, Js.fromAddress(deferred), value));
  }

  Js error(String message) =>
      _result((output) => _error(env, nullptr, string(message), output));
  void throwError(Object error, {bool typeError = false}) {
    final message = string('$error');
    final value = _result(
      (output) => typeError
          ? _typeError(env, nullptr, message, output)
          : _error(env, nullptr, message, output),
    );
    // Throwing leaves a pending exception intentionally; the callback returns null.
    _check(_throwError(env, value));
  }

  int threadsafe(
    Pointer<NativeFunction<NapiThreadsafeCallback>> callback,
    int context, {
    Pointer<NativeFunction<NapiFinalizer>>? finalizer,
  }) {
    final pointer = _result(
      (output) => _createThreadsafe(
        env,
        nullptr,
        nullptr,
        string('Dart event loop'),
        0,
        1,
        Js.fromAddress(context),
        finalizer ?? nullptr,
        Js.fromAddress(context),
        callback,
        output,
      ),
    );
    return pointer.address;
  }

  void refThreadsafe(int function) =>
      _check(_refThreadsafe(env, Js.fromAddress(function)));

  void unrefThreadsafe(int function) =>
      _check(_unrefThreadsafe(env, Js.fromAddress(function)));

  void wakeThreadsafe(int function) =>
      _check(_callThreadsafe(Js.fromAddress(function), nullptr, 0));
}
