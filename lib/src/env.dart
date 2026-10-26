import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../sys/node.dart' as node;
import '_internal/native_runtime.dart';

/// JavaScript's `undefined`. Omitted arguments are distinguished by argument count.
const undefined = JsUndefined._();

final class JsUndefined {
  const JsUndefined._();

  @override
  String toString() => 'undefined';
}

/// A value thrown by JavaScript, preserved without string coercion.
final class JsException implements Exception {
  JsException(Object? value)
    : _value = value is _JsValue ? value._env._retain<_JsValue>(value) : value;

  final Object? _value;

  /// The original thrown value, borrowed from the current scope for JS objects.
  Object? get value {
    final value = _value;
    return value is JsReference<_JsValue> ? value.value : value;
  }

  @override
  String toString() => 'JavaScript exception';
}

final class _Scope {
  final arena = Arena();
  bool active = true;

  void close() {
    active = false;
    arena.releaseAll();
  }
}

abstract class _JsValue {
  _JsValue(this._env, this._handle, this._scope);

  final Env _env;
  final node.NapiValue _handle;
  final _Scope _scope;

  void _check() {
    _env._checkOpen();
    if (!_scope.active) {
      throw StateError('JavaScript value has left its scope; retain it first');
    }
  }
}

/// A borrowed JavaScript object, valid during its callback or [Env.withScope].
///
/// Use [retain] to keep the object across calls. Property access invokes normal
/// JavaScript behavior, including getters, setters and proxy traps.
base class JsObject extends _JsValue {
  JsObject._(super.env, super.handle, super.scope);

  Object? operator [](String key) => get<Object?>(key);

  T get<T>(String key) {
    _check();
    final result = _env._arena<node.NapiValue>();
    _env._check(
      node.napiGetProperty(_env._handle, _handle, _env._encode(key), result),
    );
    return _env._decode<T>(result.value);
  }

  void operator []=(String key, Object? value) {
    _check();
    _env._check(
      node.napiSetProperty(
        _env._handle,
        _handle,
        _env._encode(key),
        _env._encode(value),
      ),
    );
  }

  JsReference<JsObject> retain() => _env._retain<JsObject>(this);
}

/// A borrowed JavaScript function.
final class JsFunction extends JsObject {
  JsFunction._(super.env, super.handle, super.scope) : super._();

  Object? call(List<Object?> arguments, {Object? receiver = undefined}) {
    _check();
    final values = _env._arena<node.NapiValue>(arguments.length);
    for (var i = 0; i < arguments.length; i++) {
      values[i] = _env._encode(arguments[i]);
    }
    final result = _env._arena<node.NapiValue>();
    _env._check(
      node.napiCallFunction(
        _env._handle,
        _env._encode(receiver),
        _handle,
        arguments.length,
        values,
        result,
      ),
    );
    return _env._decode<Object?>(result.value);
  }

  @override
  JsReference<JsFunction> retain() => _env._retain<JsFunction>(this);
}

/// A borrowed JavaScript symbol. Its identity is kept when passed back to JS.
final class JsSymbol extends _JsValue {
  JsSymbol._(super.env, super.handle, super.scope);

  JsReference<JsSymbol> retain() => _env._retain<JsSymbol>(this);
}

final class _ReferenceCleanup {
  const _ReferenceCleanup(this.env, this.address);
  final Env env;
  final int address;

  void release() => env._releaseReference(address, check: false);
}

/// An owned JavaScript reference. Release it with [dispose] when no longer used.
///
/// Otherwise it is released when this Dart reference is collected or its Node
/// environment ends. Cross-heap cycles still require explicit disposal.
final class JsReference<T> {
  JsReference._(this._env, this._reference, this._boxed) {
    _finalizer.attach(
      this,
      _ReferenceCleanup(_env, _reference.address),
      detach: this,
    );
  }

  static final _finalizer = Finalizer<_ReferenceCleanup>(
    (cleanup) => cleanup.release(),
  );
  final Env _env;
  final node.NapiRef _reference;
  final bool _boxed;
  bool _disposed = false;

  /// Gets a value borrowed from the current callback or [Env.withScope].
  T get value {
    _env._checkOpen();
    if (_disposed) throw StateError('JavaScript reference is disposed');
    final result = _env._arena<node.NapiValue>();
    _env._check(node.napiGetReferenceValue(_env._handle, _reference, result));
    var value = result.value;
    if (_boxed) {
      final inner = _env._arena<node.NapiValue>();
      _env._check(
        node.napiGetProperty(_env._handle, value, _env._encode('value'), inner),
      );
      value = inner.value;
    }
    return _env._decode<T>(value);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _finalizer.detach(this);
    _env._releaseReference(_reference.address);
  }
}

/// Arguments supplied to a JavaScript call, with strict Dart conversions.
final class JsArguments {
  JsArguments._(this._env, this._values, this._scope);
  final Env _env;
  final List<node.NapiValue> _values;
  final _Scope _scope;

  int get length => _values.length;
  bool get isEmpty => _values.isEmpty;

  Object? operator [](int index) => get<Object?>(index);

  /// Reads bool, int, double, num, String, BigInt or a JS value without coercion.
  ///
  /// `int` accepts only finite integral Numbers within JavaScript's safe range.
  /// Nullable types accept null; undefined remains [undefined].
  T get<T>(int index) {
    if (!_scope.active) {
      throw StateError('JavaScript arguments left their scope');
    }
    if (index < 0 || index >= _values.length) {
      throw ArgumentError('Missing argument at index $index');
    }
    return _env._decode<T>(_values[index]);
  }
}

final class _BoundObject {
  _BoundObject(this.value, this.definition, this.finalize);
  final Object value;
  final Object definition;
  final void Function()? finalize;
}

/// Dart operations on the Node environment supplied to a module's register hook.
///
/// Values are borrowed for the duration of a call. Registration callbacks stay
/// alive until the environment ends. Env cannot be sent to another isolate.
final class Env {
  Env._(this._runtime) {
    _callback = NativeCallable<node.NapiCallback>.isolateLocal(
      (node.NapiEnv env, node.NapiCallbackInfo info) => _dispatch(env, info),
    )..keepIsolateAlive = false;
    _getter = NativeCallable<node.NapiCallback>.isolateLocal(
      (node.NapiEnv env, node.NapiCallbackInfo info) =>
          _dispatch(env, info, callbacks: _getters),
    )..keepIsolateAlive = false;
    _setter = NativeCallable<node.NapiCallback>.isolateLocal(
      (node.NapiEnv env, node.NapiCallbackInfo info) =>
          _dispatch(env, info, callbacks: _setters),
    )..keepIsolateAlive = false;
    _tag = calloc<node.NapiTypeTag>();
    _tag.ref
      ..lower = _tag.address
      ..upper = _runtime.ownerAddress;
    _runtime.onFinalize = _finalize;
  }

  final NativeRuntime _runtime;
  late final NativeCallable<node.NapiCallback> _callback;
  late final NativeCallable<node.NapiCallback> _getter;
  late final NativeCallable<node.NapiCallback> _setter;
  late final Pointer<node.NapiTypeTag> _tag;
  final _callbacks =
      <int, node.NapiValue Function(JsArguments, node.NapiValue)>{};
  final _getters =
      <int, node.NapiValue Function(JsArguments, node.NapiValue)>{};
  final _setters =
      <int, node.NapiValue Function(JsArguments, node.NapiValue)>{};
  final _objects = <int, _BoundObject>{};
  final _references = <int>{};
  int _nextToken = 1;
  bool _closed = false;
  _Scope? _scope;

  node.NapiEnv get _handle => _runtime.env;

  Arena get _arena {
    _checkOpen();
    final scope = _scope;
    if (scope == null) {
      throw StateError('Use Env.withScope outside a JavaScript callback');
    }
    return scope.arena;
  }

  void _checkOpen() {
    if (_closed) throw StateError('Node environment is closed');
  }

  /// Opens a temporary handle scope for work outside a registered callback.
  ///
  /// Borrowed JS values cannot be used after this scope ends. Return Dart values
  /// or owned [JsReference]s instead.
  R withScope<R>(R Function() body) {
    _checkOpen();
    return using((arena) {
      final handle = arena<node.NapiHandleScope>();
      final status = node.napiOpenHandleScope(_handle, handle);
      if (status != node.NapiStatus.ok.index) {
        throw StateError('Cannot open Node handle scope: $status');
      }
      try {
        return _inScope(body);
      } finally {
        node.napiCloseHandleScope(_handle, handle.value);
      }
    });
  }

  JsObject get global => JsObject._(
    this,
    _result((out) => node.napiGetGlobal(_handle, out)),
    _scope!,
  );

  JsObject object() => JsObject._(
    this,
    _result((out) => node.napiCreateObject(_handle, out)),
    _scope!,
  );

  JsSymbol symbol([String? description]) => JsSymbol._(
    this,
    _result(
      (out) => node.napiCreateSymbol(
        _handle,
        description == null ? nullptr : _encode(description),
        out,
      ),
    ),
    _scope!,
  );

  JsFunction function(String name, Object? Function(JsArguments) body) {
    final (nativeName, length) = _functionName(name);
    final token = _nextToken++;
    _callbacks[token] = (arguments, receiver) {
      return _encode(body(arguments));
    };
    try {
      final handle = _result(
        (out) => node.napiCreateFunction(
          _handle,
          nativeName,
          length,
          _runtime.callback,
          _callbackData(token),
          out,
        ),
      );
      _nameFunction(handle, name);
      return JsFunction._(this, handle, _scope!);
    } catch (_) {
      _callbacks.remove(token);
      rethrow;
    }
  }

  /// Defines a JavaScript class whose instances own Dart objects of type T.
  ///
  /// Finalizers run after the JS GC notification is delivered to Dart, or during
  /// environment cleanup. Cleanup finalizers must not access JavaScript.
  JsFunction defineClass<T extends Object>(
    String name, {
    required T Function(JsArguments) constructor,
    Map<String, Object? Function(T, JsArguments)> methods = const {},
    Map<String, Object? Function(T)> getters = const {},
    Map<String, void Function(T, JsArguments)> setters = const {},
    void Function(T)? finalize,
  }) {
    final (nativeName, length) = _functionName(name);
    for (final key in methods.keys) {
      if (getters.containsKey(key) || setters.containsKey(key)) {
        throw ArgumentError('Member $key is both a method and an accessor');
      }
    }
    final definition = Object();
    final registrations = <int>[];
    int register(node.NapiValue Function(JsArguments, node.NapiValue) body) {
      final token = _nextToken++;
      _callbacks[token] = body;
      registrations.add(token);
      return token;
    }

    T receiver(node.NapiValue handle) {
      final valid = _arena<Bool>();
      final status = node.napiCheckObjectTypeTag(_handle, handle, _tag, valid);
      if (status != node.NapiStatus.ok.index || !valid.value) {
        throw ArgumentError('Invalid $name receiver');
      }
      final token = _arena<Pointer<Void>>();
      _check(node.napiUnwrap(_handle, handle, token));
      final object = _objects[token.value.address];
      if (object == null || !identical(object.definition, definition)) {
        throw ArgumentError('Invalid $name receiver');
      }
      return object.value as T;
    }

    final constructorToken = register((arguments, self) {
      final value = constructor(arguments);
      final token = _nextToken++;
      final bound = _BoundObject(
        value,
        definition,
        finalize == null ? null : () => finalize(value),
      );
      _check(node.napiTypeTagObject(_handle, self, _tag));
      _objects[token] = bound;
      try {
        _check(_runtime.wrap(self, token));
      } catch (_) {
        _objects.remove(token);
        rethrow;
      }
      return self;
    });
    final keys = {...methods.keys, ...getters.keys, ...setters.keys};
    final properties = _arena<node.NapiPropertyDescriptor>(keys.length);
    var index = 0;
    try {
      for (final key in keys) {
        final descriptor = properties[index++];
        descriptor
          ..name = _encode(key)
          ..attributes = node.napiConfigurable;
        final method = methods[key];
        if (method != null) {
          final token = register(
            (args, self) => _encode(method(receiver(self), args)),
          );
          descriptor
            ..method = _runtime.callback
            ..data = _callbackData(token)
            ..attributes = node.napiWritable | node.napiConfigurable;
          continue;
        }
        final getter = getters[key];
        final setter = setters[key];
        // Getter/setter functions have independent entry points: JS can call an
        // accessor directly with any argument count.
        final token = _nextToken++;
        registrations.add(token);
        descriptor.data = _callbackData(token, accessor: true);
        if (getter != null) {
          _getters[token] = (args, self) => _encode(getter(receiver(self)));
          descriptor.getter = _runtime.callback;
        }
        if (setter != null) {
          _setters[token] = (args, self) {
            setter(receiver(self), args);
            return _encode(undefined);
          };
          descriptor.setter = _runtime.setter;
        }
      }
      final handle = _result(
        (out) => node.napiDefineClass(
          _handle,
          nativeName,
          length,
          _runtime.callback,
          _callbackData(constructorToken),
          keys.length,
          properties,
          out,
        ),
      );
      _nameFunction(handle, name);
      // Only this registration requires new; ordinary functions remain callable.
      _constructors.add(constructorToken);
      return JsFunction._(this, handle, _scope!);
    } catch (_) {
      for (final token in registrations) {
        _callbacks.remove(token);
        _getters.remove(token);
        _setters.remove(token);
      }
      rethrow;
    }
  }

  final _constructors = <int>{};

  Pointer<Void> _callbackData(int token, {bool accessor = false}) {
    final result = _arena<Pointer<Void>>();
    _check(
      _runtime.createCallbackData(
        token,
        accessor ? _getter.nativeFunction : _callback.nativeFunction,
        accessor ? _setter.nativeFunction : nullptr,
        result,
      ),
    );
    return result.value;
  }

  (Pointer<Char>, int) _functionName(String name) {
    final bytes = utf8.encode(name);
    final data = _arena<Uint8>(bytes.length + 1);
    data.asTypedList(bytes.length).setAll(0, bytes);
    return (data.cast(), bytes.length);
  }

  void _nameFunction(node.NapiValue function, String name) {
    final descriptor = _arena<node.NapiPropertyDescriptor>();
    descriptor.ref
      ..name = _encode('name')
      ..value = _encode(name)
      ..attributes = node.napiConfigurable;
    _check(node.napiDefineProperties(_handle, function, 1, descriptor));
  }

  R _inScope<R>(R Function() body) {
    _checkOpen();
    final parent = _scope;
    final current = _Scope();
    _scope = current;
    try {
      return body();
    } finally {
      _scope = parent;
      current.close();
    }
  }

  node.NapiValue _dispatch(
    node.NapiEnv env,
    node.NapiCallbackInfo info, {
    Map<int, node.NapiValue Function(JsArguments, node.NapiValue)>? callbacks,
  }) {
    if (_closed || env != _handle) return nullptr;
    try {
      return _inScope(() {
        try {
          final count = _arena<Size>();
          final data = _arena<Pointer<Void>>();
          final self = _arena<node.NapiValue>();
          _check(node.napiGetCbInfo(env, info, count, nullptr, self, data));
          final values = _arena<node.NapiValue>(count.value);
          _check(node.napiGetCbInfo(env, info, count, values, self, data));
          final token = _runtime.callbackToken(data.value);
          final body = (callbacks ?? _callbacks)[token];
          if (body == null) {
            throw StateError('JavaScript callback was released');
          }
          if (callbacks == null && _constructors.contains(token)) {
            final target = _arena<node.NapiValue>();
            _check(node.napiGetNewTarget(env, info, target));
            if (target.value == nullptr) {
              throw ArgumentError('Constructor requires new');
            }
          }
          return body(
            JsArguments._(
              this,
              List.generate(count.value, (i) => values[i]),
              _scope!,
            ),
            self.value,
          );
        } catch (error) {
          _reportError(error);
          return nullptr;
        }
      });
    } catch (_) {
      _fallbackError();
      return nullptr;
    } finally {
      try {
        _runtime.wake();
      } catch (_) {
        _fallbackError();
      }
    }
  }

  node.NapiValue _result(int Function(Pointer<node.NapiValue>) operation) {
    final out = _arena<node.NapiValue>();
    _check(operation(out));
    return out.value;
  }

  void _check(int status) {
    if (status == node.NapiStatus.ok.index) return;
    final pending = _arena<Bool>();
    if (node.napiIsExceptionPending(_handle, pending) == 0 && pending.value) {
      final value = _arena<node.NapiValue>();
      if (node.napiGetAndClearLastException(_handle, value) == 0) {
        throw JsException(_decode<Object?>(value.value));
      }
    }
    throw StateError('Node-API operation failed: $status');
  }

  T _decode<T>(node.NapiValue handle) {
    final type = _arena<Int32>();
    _check(node.napiTypeof(_handle, handle, type));
    Object? value;
    switch (node.NapiValueType.values[type.value]) {
      case node.NapiValueType.undefined:
        value = undefined;
      case node.NapiValueType.nullValue:
        value = null;
      case node.NapiValueType.boolean:
        final out = _arena<Bool>();
        _check(node.napiGetValueBool(_handle, handle, out));
        value = out.value;
      case node.NapiValueType.number:
        final out = _arena<Double>();
        _check(node.napiGetValueDouble(_handle, handle, out));
        final number = out.value;
        if (T == int || T == _typeOf<int?>()) {
          if (!number.isFinite ||
              number.abs() > 9007199254740991 ||
              number != number.truncateToDouble()) {
            throw RangeError('Expected a JavaScript safe integer');
          }
          value = number.toInt();
        } else if (T == double || T == _typeOf<double?>()) {
          value = number;
        } else {
          value =
              number.isFinite &&
                  number.abs() <= 9007199254740991 &&
                  number == number.truncateToDouble() &&
                  !(number == 0 && number.isNegative)
              ? number.toInt()
              : number;
        }
      case node.NapiValueType.string:
        final length = _arena<Size>();
        _check(
          node.napiGetValueStringUtf16(_handle, handle, nullptr, 0, length),
        );
        final chars = _arena<Uint16>(length.value + 1);
        _check(
          node.napiGetValueStringUtf16(
            _handle,
            handle,
            chars,
            length.value + 1,
            length,
          ),
        );
        value = String.fromCharCodes(chars.asTypedList(length.value));
      case node.NapiValueType.bigint:
        final count = _arena<Size>();
        _check(
          node.napiGetValueBigintWords(
            _handle,
            handle,
            nullptr,
            count,
            nullptr,
          ),
        );
        final sign = _arena<Int32>();
        final words = _arena<Uint64>(count.value);
        _check(
          node.napiGetValueBigintWords(_handle, handle, sign, count, words),
        );
        var integer = BigInt.zero;
        for (var i = count.value - 1; i >= 0; i--) {
          integer = (integer << 64) | BigInt.from(words[i]).toUnsigned(64);
        }
        value = sign.value == 0 ? integer : -integer;
      case node.NapiValueType.symbol:
        value = JsSymbol._(this, handle, _scope!);
      case node.NapiValueType.function:
        value = JsFunction._(this, handle, _scope!);
      case node.NapiValueType.object:
        value = JsObject._(this, handle, _scope!);
      case node.NapiValueType.external:
        throw ArgumentError('External Node-API values require raw bindings');
    }
    if (value is! T) {
      throw ArgumentError('Expected $T, received ${value.runtimeType}');
    }
    return value;
  }

  node.NapiValue _encode(Object? value) {
    if (value == null) return _result((out) => node.napiGetNull(_handle, out));
    if (identical(value, undefined)) {
      return _result((out) => node.napiGetUndefined(_handle, out));
    }
    if (value is _JsValue) {
      value._check();
      if (!identical(value._env, this)) {
        throw ArgumentError('JavaScript value belongs to another environment');
      }
      return value._handle;
    }
    if (value is bool) {
      return _result((out) => node.napiGetBoolean(_handle, value, out));
    }
    if (value is int) {
      if (value < -9007199254740991 || value > 9007199254740991) {
        throw RangeError(
          'Dart int exceeds JavaScript safe integers; use BigInt',
        );
      }
      return _result(
        (out) => node.napiCreateDouble(_handle, value.toDouble(), out),
      );
    }
    if (value is double) {
      return _result((out) => node.napiCreateDouble(_handle, value, out));
    }
    if (value is String) {
      final chars = _arena<Uint16>(value.length + 1);
      chars.asTypedList(value.length).setAll(0, value.codeUnits);
      return _result(
        (out) => node.napiCreateStringUtf16(_handle, chars, value.length, out),
      );
    }
    if (value is BigInt) {
      var remaining = value.abs();
      final count = (remaining.bitLength + 63) ~/ 64;
      final words = _arena<Uint64>(count);
      final mask = (BigInt.one << 64) - BigInt.one;
      for (var i = 0; i < count; i++) {
        words[i] = (remaining & mask).toSigned(64).toInt();
        remaining >>= 64;
      }
      return _result(
        (out) => node.napiCreateBigintWords(
          _handle,
          value.isNegative ? 1 : 0,
          count,
          words,
          out,
        ),
      );
    }
    throw ArgumentError('Unsupported Dart value: ${value.runtimeType}');
  }

  JsReference<T> _retain<T>(_JsValue value) {
    value._check();
    if (!identical(value._env, this)) throw ArgumentError('Wrong environment');
    var handle = value._handle;
    final boxed = value is JsSymbol;
    if (boxed) {
      handle = _result((out) => node.napiCreateObject(_handle, out));
      final property = _arena<node.NapiPropertyDescriptor>();
      property.ref
        ..name = _encode('value')
        ..value = value._handle;
      _check(node.napiDefineProperties(_handle, handle, 1, property));
    }
    final reference = _arena<node.NapiRef>();
    _check(node.napiCreateReference(_handle, handle, 1, reference));
    _references.add(reference.value.address);
    return JsReference<T>._(this, reference.value, boxed);
  }

  void _releaseReference(int address, {bool check = true}) {
    if (_closed || !_references.contains(address)) return;
    final status = node.napiDeleteReference(
      _handle,
      node.NapiRef.fromAddress(address),
    );
    if (status == 0) {
      _references.remove(address);
    } else if (check) {
      throw StateError('Cannot release JavaScript reference: $status');
    }
  }

  void _throw(Object error) {
    if (error is JsException) {
      node.napiThrow(_handle, _encode(error.value));
      return;
    }
    String message;
    try {
      message = error.toString();
    } catch (_) {
      message = 'Dart callback failed';
    }
    final value = _encode(message);
    final node.NapiValue exception;
    if (error is RangeError) {
      exception = _result(
        (out) => node.napiCreateRangeError(_handle, nullptr, value, out),
      );
    } else if (error is ArgumentError || error is TypeError) {
      exception = _result(
        (out) => node.napiCreateTypeError(_handle, nullptr, value, out),
      );
    } else {
      exception = _result(
        (out) => node.napiCreateError(_handle, nullptr, value, out),
      );
    }
    node.napiThrow(_handle, exception);
  }

  void _reportError(Object error) {
    try {
      _throw(error);
    } catch (_) {
      _fallbackError();
    }
  }

  void _fallbackError() {
    using((arena) {
      final pending = arena<Bool>();
      if (node.napiIsExceptionPending(_handle, pending) == 0 && pending.value) {
        return;
      }
      final message = 'Cannot convert Dart callback exception to JavaScript'
          .toNativeUtf8(allocator: arena);
      node.napiThrowTypeError(_handle, nullptr, message.cast());
    });
  }

  void _finalize(int token) {
    if (_closed) return;
    final object = _objects.remove(token);
    if (object == null) return;
    final callback = object.finalize;
    if (callback != null) withScope(callback);
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    for (final reference in _references) {
      node.napiDeleteReference(_handle, node.NapiRef.fromAddress(reference));
    }
    _references.clear();
    final objects = _objects.values.toList();
    _objects.clear();
    _callbacks.clear();
    _getters.clear();
    _setters.clear();
    _constructors.clear();
    _callback.close();
    _getter.close();
    _setter.close();
    calloc.free(_tag);
    Object? firstError;
    StackTrace? firstStack;
    for (final object in objects) {
      try {
        object.finalize?.call();
      } catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }
    if (firstError != null) Error.throwWithStackTrace(firstError, firstStack!);
  }
}

// Only the compiler-generated entry imports these module lifecycle functions.
Env createEnv(NativeRuntime runtime) => Env._(runtime);

void registerEnv(
  Env env,
  node.NapiValue exports,
  void Function(Env, JsObject) register,
) => env._inScope(() {
  try {
    register(env, JsObject._(env, exports, env._scope!));
  } catch (error) {
    env._reportError(error);
    rethrow;
  }
});

void disposeEnv(Env env) => env._close();

Type _typeOf<T>() => T;
