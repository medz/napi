import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../sys/node.dart' as node;
import '_internal/annotations.dart';
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

  /// Checks for an own property without reading its value.
  bool hasOwn(String key) {
    _check();
    final result = _env._arena<Bool>();
    _env._check(
      node.napiHasOwnProperty(_env._handle, _handle, _env._encode(key), result),
    );
    return result.value;
  }

  /// Defines an own data property without invoking an inherited setter.
  void defineValue(String key, Object? value) => _defineValue(key, value);

  void _defineValue(
    Object key,
    Object? value, {
    int attributes =
        node.napiWritable | node.napiEnumerable | node.napiConfigurable,
  }) {
    _check();
    final property = _env._arena<node.NapiPropertyDescriptor>();
    property.ref
      ..name = _env._encode(key)
      ..value = _env._encode(value)
      ..attributes = attributes;
    _env._check(node.napiDefineProperties(_env._handle, _handle, 1, property));
  }

  T get<T>(String key) => _get<T>(key);

  T _get<T>(Object key) => _env._decode<T>(_property(key));

  node.NapiValue _property(Object key) {
    _check();
    final result = _env._arena<node.NapiValue>();
    _env._check(
      node.napiGetProperty(_env._handle, _handle, _env._encode(key), result),
    );
    return result.value;
  }

  T _element<T>(int index) {
    _check();
    RangeError.checkValueInInterval(index, 0, 0xffffffff, 'index');
    final result = _env._arena<node.NapiValue>();
    _env._check(node.napiGetElement(_env._handle, _handle, index, result));
    return _env._decode<T>(result.value);
  }

  int get _arrayLength {
    _check();
    final isArray = _env._arena<Bool>();
    _env._check(node.napiIsArray(_env._handle, _handle, isArray));
    if (!isArray.value) throw ArgumentError('Expected a JavaScript Array');
    final length = _env._arena<Uint32>();
    _env._check(node.napiGetArrayLength(_env._handle, _handle, length));
    return length.value;
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

  Object? call(List<Object?> arguments, {Object? receiver = undefined}) =>
      _call<Object?>(arguments, receiver: receiver);

  T _call<T>(List<Object?> arguments, {Object? receiver = undefined}) {
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
    return _env._decode<T>(result.value);
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
  JsArguments._(this._env, this._values, this._scope, [this._receiverHandle]);
  final Env _env;
  final List<node.NapiValue> _values;
  final _Scope _scope;
  final node.NapiValue? _receiverHandle;

  JsObject get _receiver {
    if (!_scope.active) {
      throw StateError('JavaScript arguments left their scope');
    }
    return _env._decode<JsObject>(_receiverHandle!);
  }

  int get length => _values.length;
  bool get isEmpty => _values.isEmpty;

  /// The environment for this call.
  Env get env => _env;

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
  _BoundObject(this.value, this.definition, this.reference, this.finalize);
  final Object value;
  final _ClassDefinition definition;
  final node.NapiRef? reference;
  final void Function()? finalize;
  Map<_ClassDefinition, _ClassSpecialization?>? _views;

  _ClassSpecialization? view(_ClassDefinition contract) {
    final candidates = contract.views;
    if (candidates == null) return null;
    final matches = [
      for (final view in candidates)
        if (view.accepts(value)) view,
    ];
    final closest = [
      for (final view in matches)
        if (!matches.any(
          (other) => other.isSubtypeOf(view) && !view.isSubtypeOf(other),
        ))
          view,
    ];
    if (closest.length > 1) {
      throw StateError(
        'Dart object matches incompatible class specializations: ${closest.map((view) => view.type).join(', ')}',
      );
    }
    return closest.firstOrNull?.members;
  }

  _ClassSpecialization? specialization(_ClassDefinition contract) {
    if (!contract.hasViews) return definition.specializations?[contract];
    final cache = _views ??= {};
    if (cache.containsKey(contract)) return cache[contract];
    final own = view(contract);
    final inherited = definition.specializations?[contract];
    final parent = contract.parent == null
        ? null
        : specialization(contract.parent!);
    final selected = [?parent, ?inherited, ?own];
    if (selected.length < 2) return cache[contract] = selected.firstOrNull;
    return cache[contract] = _ClassSpecialization(
      methods: {for (final members in selected) ...members.methods},
      getters: {for (final members in selected) ...members.getters},
      setters: {for (final members in selected) ...members.setters},
    );
  }
}

final class _ClassView<T extends Object> {
  const _ClassView(this.members);
  final _ClassSpecialization members;
  Type get type => T;
  bool accepts(Object value) => value is T;
  bool acceptsType<S>() => <S>[] is List<T>;
  bool isSubtypeOf(_ClassView other) => other.acceptsType<T>();
}

final class _PendingWrap {
  _PendingWrap(this.value);
  final Object value;
}

final class _GenericPayload {
  const _GenericPayload(this.value);

  final Object value;
}

final class _GenericValues {
  Set<_BoundObject>? origins;
}

final class _ClassDefinition {
  _ClassDefinition(this.accepts);

  final bool Function(Object) accepts;
  final pending = <_PendingWrap>[];
  JsReference<JsFunction>? constructor;
  _ClassDefinition? parent;
  final children = <_ClassDefinition>[];
  Map<_ClassDefinition, _ClassSpecialization>? specializations;
  List<_ClassView>? views;
  bool hasViews = false;

  _ClassDefinition select(Object value) {
    _ClassDefinition? selected;
    for (final child in children) {
      if (!child.accepts(value)) continue;
      if (selected != null) {
        throw StateError(
          'Dart object matches more than one JavaScript subclass',
        );
      }
      selected = child;
    }
    return selected?.select(value) ?? this;
  }
}

final class _ClassSpecialization {
  const _ClassSpecialization({
    required this.methods,
    required this.getters,
    required this.setters,
  });

  final Map<String, Object? Function(Object, JsArguments)> methods;
  final Map<String, Object? Function(Object)> getters;
  final Map<String, void Function(Object, JsArguments)> setters;
}

final class _BoundFunction {
  const _BoundFunction(this.value, this.signature, this.reference);
  final Function value;
  final Type signature;
  final node.NapiRef reference;
}

final class _StreamState<T> {
  _StreamState(Stream<T> value, this.write) : iterator = StreamIterator(value);

  final StreamIterator<T> iterator;
  final Object? Function(T) write;
  Future<void> _tail = Future<void>.value();
  Future<void>? _cancellation;
  bool _closed = false;

  Future<(bool, T?)> next() {
    final result = _tail.then<(bool, T?)>((_) async {
      if (_closed) return (true, null);
      try {
        if (await iterator.moveNext()) return (false, iterator.current);
        _closed = true;
        return (true, null);
      } catch (_) {
        _closed = true;
        rethrow;
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> cancel() {
    _closed = true;
    return _cancellation ??= Future<void>.sync(() => iterator.cancel());
  }
}

/// Dart operations on the Node environment supplied to a module's register hook.
///
/// Values are borrowed for the duration of a call. Env cannot be sent to another
/// isolate.
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
  final _identity = Expando<int>();
  final _genericPayloads = Expando<_GenericPayload>();
  final _classes = <Type, _ClassDefinition?>{};
  Map<Type, Type>? _classBounds;
  int _objectDepth = 0;
  final _importedFunctions = Expando<JsReference<JsFunction>>();
  final _functionIdentity = Expando<Map<Type, int>>();
  final _functions = <int, _BoundFunction>{};
  final _references = <int>{};
  JsReference<JsSymbol>? _asyncIteratorSymbol;
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

  /// Creates a function that retains [body] until JavaScript collects it.
  JsFunction function(String name, Object? Function(JsArguments) body) =>
      _newFunction(name, body);

  JsFunction _newFunction<F extends Function>(
    String name,
    Object? Function(JsArguments) body, {
    F? identity,
  }) {
    final (nativeName, length) = _functionName(name);
    final token = _nextToken++;
    final previous = identity == null ? null : _functionIdentity[identity]?[F];
    _callbacks[token] = (arguments, receiver) {
      return _encode(body(arguments));
    };
    Pointer<Void>? data;
    node.NapiRef? reference;
    try {
      data = _callbackData(token);
      final handle = _result(
        (out) => node.napiCreateFunction(
          _handle,
          nativeName,
          length,
          _runtime.callback,
          data!,
          out,
        ),
      );
      _nameFunction(handle, name);
      if (identity != null) {
        final out = _arena<node.NapiRef>();
        _check(node.napiCreateReference(_handle, handle, 0, out));
        reference = out.value;
        _references.add(reference.address);
        _functions[token] = _BoundFunction(identity, F, reference);
        (_functionIdentity[identity] ??= {})[F] = token;
      }
      _check(_runtime.trackFunction(handle, data));
      return JsFunction._(this, handle, _scope!);
    } catch (_) {
      _callbacks.remove(token);
      _functions.remove(token);
      if (identity != null) {
        final signatures = _functionIdentity[identity];
        if (signatures?[F] == token) {
          if (previous == null) {
            signatures!.remove(F);
          } else {
            signatures![F] = previous;
          }
          if (signatures.isEmpty) _functionIdentity[identity] = null;
        }
      }
      if (reference != null) {
        _releaseReference(reference.address, check: false);
      }
      if (data != null) _runtime.trackFunction(nullptr, data);
      rethrow;
    }
  }

  // Called by compiler-generated bindings.
  // ignore: unused_element
  F _readFunction<F extends Function>(
    JsFunction value,
    F Function(JsReference<JsFunction>) bind,
  ) {
    _encode(value);
    final reference = value.retain();
    try {
      final function = bind(reference);
      _importedFunctions[function] = reference;
      return function;
    } catch (_) {
      reference.dispose();
      rethrow;
    }
  }

  // ignore: unused_element
  R _invokeFunction<R>(
    JsReference<JsFunction> reference,
    R Function(JsFunction) invoke,
  ) {
    R call() => invoke(reference.value);
    return _scope == null ? withScope(call) : call();
  }

  // ignore: unused_element
  JsFunction _writeFunction<F extends Function>(
    F value,
    Object? Function(JsArguments) invoke, {
    bool preserveIdentity = true,
  }) {
    _arena;
    final original = _importedFunctions[value];
    if (preserveIdentity && original != null) return original.value;
    final cached = _functions[_functionIdentity[value]?[F]];
    if (cached != null) {
      final handle = _result(
        (out) => node.napiGetReferenceValue(_handle, cached.reference, out),
      );
      if (handle != nullptr) return JsFunction._(this, handle, _scope!);
    }
    return _newFunction<F>('', invoke, identity: value);
  }

  // ignore: unused_element
  Future<T> _readFuture<T>(JsObject value, T Function(JsArguments) read) {
    final isPromise = _arena<Bool>();
    _check(node.napiIsPromise(_handle, _encode(value), isPromise));
    if (!isPromise.value) throw ArgumentError('Expected a JavaScript Promise');
    final result = Completer<T>();
    // A later conversion can fail before business code receives this Future.
    result.future.ignore();
    final resolve = function('', (arguments) {
      if (!result.isCompleted) {
        try {
          result.complete(read(arguments));
        } catch (error, stack) {
          result.completeError(error, stack);
        }
      }
      return undefined;
    });
    final reject = function('', (arguments) {
      if (!result.isCompleted) {
        try {
          result.completeError(JsException(arguments[0]));
        } catch (error, stack) {
          result.completeError(error, stack);
        }
      }
      return undefined;
    });
    value.get<JsFunction>('then').call([resolve, reject], receiver: value);
    return result.future;
  }

  // ignore: unused_element
  JsObject _writeFuture<T>(Future<T> value, Object? Function(T) write) {
    _arena;
    final ready =
        Completer<(JsReference<JsFunction>, JsReference<JsFunction>)?>();

    node.NapiValue errorValue(Object error) {
      try {
        return _errorValue(error);
      } catch (_) {
        return _errorValue(
          ArgumentError('Cannot convert Dart callback exception to JavaScript'),
        );
      }
    }

    void reject(JsFunction function, Object error) {
      function.call([_decode<Object?>(errorValue(error))]);
    }

    Future<void> settle(
      void Function(JsFunction resolve, JsFunction reject) complete,
    ) async {
      try {
        final references = await ready.future;
        if (references == null) return;
        try {
          if (!_closed) {
            withScope(() => complete(references.$1.value, references.$2.value));
          }
        } finally {
          try {
            references.$1.dispose();
          } finally {
            references.$2.dispose();
          }
        }
      } catch (_) {
        // Teardown or a failed Node operation must not leave an unhandled Future.
      }
    }

    unawaited(
      value.then<void>(
        (result) => settle((resolve, rejectFunction) {
          try {
            resolve.call([write(result)]);
          } catch (error) {
            reject(rejectFunction, error);
          }
        }),
        onError: (Object error, StackTrace stack) =>
            settle((_, rejectFunction) => reject(rejectFunction, error)),
      ),
    );

    final deferred = _arena<node.NapiDeferred>();
    final promise = _arena<node.NapiValue>();
    try {
      _check(node.napiCreatePromise(_handle, deferred, promise));
      final thenable = object();
      thenable.defineValue(
        'then',
        function('', (arguments) {
          if (ready.isCompleted) return undefined;
          JsReference<JsFunction>? resolve;
          try {
            resolve = arguments.get<JsFunction>(0).retain();
            final reject = arguments.get<JsFunction>(1).retain();
            ready.complete((resolve, reject));
          } catch (_) {
            ready.complete(null);
            resolve?.dispose();
            rethrow;
          }
          return undefined;
        }),
      );
      // Consume the opaque deferred before returning to Node. Only ordinary
      // references, covered by Env cleanup, survive the assimilation job.
      final handle = deferred.value;
      deferred.value = nullptr;
      _check(node.napiResolveDeferred(_handle, handle, thenable._handle));
      return JsObject._(this, promise.value, _scope!);
    } catch (error) {
      if (!ready.isCompleted) ready.complete(null);
      if (deferred.value != nullptr) {
        node.napiRejectDeferred(_handle, deferred.value, errorValue(error));
      }
      rethrow;
    }
  }

  JsSymbol get _asyncIterator {
    final cached = _asyncIteratorSymbol;
    if (cached != null) return cached.value;
    final symbol = global
        .get<JsObject>('Symbol')
        .get<JsSymbol>('asyncIterator');
    _asyncIteratorSymbol = symbol.retain();
    return symbol;
  }

  Future<T> _awaitValue<T>(Object? value, T Function(JsArguments) read) {
    final handle = _encode(value);
    final deferred = _arena<node.NapiDeferred>();
    final promise = _arena<node.NapiValue>();
    _check(node.napiCreatePromise(_handle, deferred, promise));
    _check(node.napiResolveDeferred(_handle, deferred.value, handle));
    return _readFuture(JsObject._(this, promise.value, _scope!), read);
  }

  JsObject _streamRequest<R>(
    JsArguments arguments,
    Future<R> Function() operation,
    Object? Function(R) write,
  ) {
    final receiver = arguments._receiver.retain();
    try {
      return _writeFuture(
        Future<R>.sync(operation).whenComplete(receiver.dispose),
        write,
      );
    } catch (_) {
      receiver.dispose();
      rethrow;
    }
  }

  // ignore: unused_element
  JsObject _writeStream<T>(Stream<T> value, Object? Function(T) write) {
    if (!_classes.containsKey(_StreamState<T>)) {
      final symbol = _asyncIterator;
      JsObject result(_StreamState<T> state, (bool, T?) step) {
        final object = this.object();
        object.defineValue('done', step.$1);
        try {
          object.defineValue(
            'value',
            step.$1 ? undefined : state.write(step.$2 as T),
          );
        } catch (_) {
          state.cancel().ignore();
          rethrow;
        }
        return object;
      }

      final constructor = defineClass<_StreamState<T>>(
        'DartStreamIterator',
        constructor: (_) =>
            throw StateError('Stream iterators cannot be constructed'),
        methods: {
          'next': (state, arguments) => _streamRequest(
            arguments,
            state.next,
            (step) => result(state, step),
          ),
          'return': (state, arguments) => _streamRequest(arguments, () async {
            await state.cancel();
            return (true, null as T?);
          }, (step) => result(state, step)),
        },
        finalize: (state) => state.cancel().ignore(),
      );
      constructor
          .get<JsObject>('prototype')
          ._defineValue(
            symbol,
            function(
              '[Symbol.asyncIterator]',
              (arguments) => arguments._receiver,
            ),
            attributes: node.napiWritable | node.napiConfigurable,
          );
    }
    return wrap(_StreamState(value, write));
  }

  // ignore: unused_element
  Stream<T> _readStream<T>(JsObject value, T Function(JsArguments) read) {
    final method = value._get<JsFunction>(_asyncIterator);
    JsReference<JsObject>? source = value.retain();
    JsReference<JsFunction>? factory;
    try {
      factory = method.retain();
    } catch (_) {
      source.dispose();
      rethrow;
    }
    JsReference<JsObject>? iterator;
    JsReference<JsFunction>? next;
    late final StreamController<T> controller;
    var stopped = false;
    var pulling = false;
    Future<void>? cancellation;

    void releaseSource() {
      try {
        source?.dispose();
      } finally {
        source = null;
        factory?.dispose();
        factory = null;
      }
    }

    void release() {
      try {
        releaseSource();
      } finally {
        try {
          iterator?.dispose();
        } finally {
          iterator = null;
          next?.dispose();
          next = null;
        }
      }
    }

    Future<void> closeIterator() {
      try {
        if (_closed || iterator == null) return Future<void>.value();
        return withScope(() {
          final receiver = iterator!.value;
          final method = receiver['return'];
          if (method == null || identical(method, undefined)) {
            return Future<void>.value();
          }
          if (method is! JsFunction) {
            throw ArgumentError('Async iterator return must be a function');
          }
          return _awaitValue<void>(method.call([], receiver: receiver), (args) {
            args.get<JsObject>(0);
          });
        });
      } finally {
        release();
      }
    }

    Future<void> cancel() {
      if (cancellation != null) return cancellation!;
      if (stopped) {
        release();
        return Future<void>.value();
      }
      stopped = true;
      return cancellation = Future<void>.sync(closeIterator);
    }

    Future<void> pump() async {
      if (pulling || stopped) return;
      pulling = true;
      try {
        while (!stopped && !controller.isPaused) {
          var codecFailed = false;
          try {
            final step = await withScope(() {
              final receiver = iterator!.value;
              return _awaitValue<(bool, T?)>(
                next!.value.call([], receiver: receiver),
                (arguments) {
                  if (stopped) return (true, null);
                  final object = arguments.get<JsObject>(0);
                  final done = _result(
                    (out) => node.napiCoerceToBool(
                      _handle,
                      object._property('done'),
                      out,
                    ),
                  );
                  if (_decode<bool>(done)) return (true, null);
                  final element = object._property('value');
                  try {
                    return (
                      false,
                      read(JsArguments._(this, [element], _scope!)),
                    );
                  } catch (_) {
                    codecFailed = true;
                    rethrow;
                  }
                },
              );
            });
            if (stopped) break;
            if (step.$1) {
              stopped = true;
              release();
              controller.close().ignore();
              break;
            }
            controller.add(step.$2 as T);
          } catch (error, stack) {
            if (stopped) break;
            stopped = true;
            if (codecFailed) {
              try {
                await Future<void>.sync(closeIterator);
              } catch (_) {
                // Preserve the element conversion error if cleanup also fails.
              }
            } else {
              release();
            }
            controller.addError(error, stack);
            controller.close().ignore();
            break;
          }
        }
      } finally {
        pulling = false;
      }
    }

    controller = StreamController<T>(
      sync: true,
      onListen: () {
        try {
          withScope(() {
            final receiver = source!.value;
            final object = factory!.value._call<JsObject>(
              [],
              receiver: receiver,
            );
            final method = object.get<JsFunction>('next');
            iterator = object.retain();
            next = method.retain();
          });
          releaseSource();
          pump().ignore();
        } catch (error, stack) {
          stopped = true;
          release();
          scheduleMicrotask(() {
            controller.addError(error, stack);
            controller.close().ignore();
          });
        }
      },
      onResume: () => pump().ignore(),
      onCancel: cancel,
    );
    return controller.stream;
  }

  // ignore: unused_element
  DateTime _readDate(JsObject value) {
    final handle = _encode(value);
    final isDate = _arena<Bool>();
    _check(node.napiIsDate(_handle, handle, isDate));
    if (!isDate.value) throw ArgumentError('Expected a JavaScript Date');
    final time = _arena<Double>();
    _check(node.napiGetDateValue(_handle, handle, time));
    if (!time.value.isFinite) throw RangeError('Invalid JavaScript Date');
    return DateTime.fromMillisecondsSinceEpoch(time.value.toInt(), isUtc: true);
  }

  // ignore: unused_element
  JsObject _writeDate(DateTime value) {
    final milliseconds = value.millisecondsSinceEpoch;
    RangeError.checkValueInInterval(
      milliseconds,
      -8640000000000000,
      8640000000000000,
      'millisecondsSinceEpoch',
    );
    return JsObject._(
      this,
      _result(
        (out) => node.napiCreateDate(_handle, milliseconds.toDouble(), out),
      ),
      _scope!,
    );
  }

  // ignore: unused_element
  List<T> _readList<T>(JsObject value, T Function(JsObject, int) read) {
    _encode(value);
    return List<T>.generate(value._arrayLength, (index) => read(value, index));
  }

  JsObject _array(int length) => JsObject._(
    this,
    _result((out) => node.napiCreateArrayWithLength(_handle, length, out)),
    _scope!,
  );

  // ignore: unused_element
  JsObject _writeList<T>(List<T> value, Object? Function(T) write) {
    final length = value.length;
    final result = _array(length);
    for (var index = 0; index < length; index++) {
      result.defineValue('$index', write(value[index]));
    }
    return result;
  }

  // ignore: unused_element
  Map<String, V> _readMap<V>(
    JsObject value,
    V Function(JsObject, String) read,
  ) {
    final handle = _encode(value);
    final keys = JsObject._(
      this,
      _result(
        (out) => node.napiGetAllPropertyNames(
          _handle,
          handle,
          node.NapiKeyCollectionMode.ownOnly.index,
          node.napiKeyEnumerable | node.napiKeySkipSymbols,
          node.NapiKeyConversion.numbersToStrings.index,
          out,
        ),
      ),
      _scope!,
    );
    final length = keys._arrayLength;
    final result = <String, V>{};
    for (var index = 0; index < length; index++) {
      final key = keys._element<String>(index);
      if (!value.hasOwn(key)) continue;
      result[key] = read(value, key);
    }
    return result;
  }

  // ignore: unused_element
  JsObject _writeMap<V>(Map<String, V> value, Object? Function(V) write) {
    final result = object();
    for (final entry in value.entries) {
      result.defineValue(entry.key, write(entry.value));
    }
    return result;
  }

  // ignore: unused_element
  Set<T> _readSet<T>(JsObject value, T Function(JsArguments) read) {
    _encode(value);
    final iterator = value
        .get<JsFunction>('values')
        ._call<JsObject>([], receiver: value);
    final next = iterator.get<JsFunction>('next');
    final result = <T>{};
    while (true) {
      final step = next._call<JsObject>([], receiver: iterator);
      final done = _result(
        (out) => node.napiCoerceToBool(_handle, step._property('done'), out),
      );
      if (_decode<bool>(done)) return result;
      final element = step._property('value');
      try {
        result.add(read(JsArguments._(this, [element], _scope!)));
      } catch (_) {
        try {
          final close = iterator['return'];
          if (close is JsFunction) close.call([], receiver: iterator);
        } catch (_) {
          // Iterator cleanup must not replace the conversion error.
        }
        rethrow;
      }
    }
  }

  // ignore: unused_element
  JsObject _writeSet<T>(Set<T> value, Object? Function(T) write) {
    final values = _array(value.length);
    var index = 0;
    for (final element in value) {
      values.defineValue('${index++}', write(element));
    }
    final constructor = global.get<JsFunction>('Set');
    final arguments = _arena<node.NapiValue>()..value = values._handle;
    return JsObject._(
      this,
      _result(
        (out) => node.napiNewInstance(
          _handle,
          constructor._handle,
          1,
          arguments,
          out,
        ),
      ),
      _scope!,
    );
  }

  void _checkAttached(node.NapiValue buffer) {
    final detached = _arena<Bool>();
    _check(node.napiIsDetachedArraybuffer(_handle, buffer, detached));
    if (detached.value) throw ArgumentError('ArrayBuffer is detached');
  }

  Uint8List _copyBytes(Pointer<Void> data, int length) {
    final bytes = Uint8List(length);
    if (length > 0) {
      if (data == nullptr) throw StateError('Buffer has no accessible data');
      bytes.setRange(0, length, data.cast<Uint8>().asTypedList(length));
    }
    return bytes;
  }

  node.NapiValue _createArrayBuffer(Uint8List bytes) {
    final data = _arena<Pointer<Void>>();
    final buffer = _result(
      (out) => node.napiCreateArraybuffer(_handle, bytes.length, data, out),
    );
    if (bytes.isNotEmpty) {
      data.value.cast<Uint8>().asTypedList(bytes.length).setAll(0, bytes);
    }
    return buffer;
  }

  // ignore: unused_element
  ByteBuffer _readByteBuffer(JsObject value) {
    final handle = _encode(value);
    final isBuffer = _arena<Bool>();
    _check(node.napiIsArraybuffer(_handle, handle, isBuffer));
    if (!isBuffer.value) {
      throw ArgumentError('Expected a JavaScript ArrayBuffer');
    }
    _checkAttached(handle);
    final data = _arena<Pointer<Void>>();
    final length = _arena<Size>();
    _check(node.napiGetArraybufferInfo(_handle, handle, data, length));
    return _copyBytes(data.value, length.value).buffer;
  }

  // ignore: unused_element
  JsObject _writeByteBuffer(ByteBuffer value) =>
      JsObject._(this, _createArrayBuffer(value.asUint8List()), _scope!);

  // ignore: unused_element
  ByteData _readByteData(JsObject value) {
    final handle = _encode(value);
    final isView = _arena<Bool>();
    _check(node.napiIsDataview(_handle, handle, isView));
    if (!isView.value) throw ArgumentError('Expected a JavaScript DataView');
    final data = _arena<Pointer<Void>>();
    final length = _arena<Size>();
    final buffer = _arena<node.NapiValue>();
    _check(
      node.napiGetDataviewInfo(_handle, handle, length, data, buffer, nullptr),
    );
    _checkAttached(buffer.value);
    return _copyBytes(data.value, length.value).buffer.asByteData();
  }

  // ignore: unused_element
  JsObject _writeByteData(ByteData value) {
    final length = value.lengthInBytes;
    final buffer = _createArrayBuffer(
      value.buffer.asUint8List(value.offsetInBytes, length),
    );
    return JsObject._(
      this,
      _result(
        (out) => node.napiCreateDataview(_handle, length, buffer, 0, out),
      ),
      _scope!,
    );
  }

  // ignore: unused_element
  T _readTypedData<T extends TypedData>(JsObject value, int expectedKind) {
    final handle = _encode(value);
    final isTypedArray = _arena<Bool>();
    _check(node.napiIsTypedarray(_handle, handle, isTypedArray));
    if (!isTypedArray.value) {
      throw ArgumentError('Expected a JavaScript TypedArray');
    }
    final kind = _arena<Int32>();
    final length = _arena<Size>();
    final data = _arena<Pointer<Void>>();
    final buffer = _arena<node.NapiValue>();
    _check(
      node.napiGetTypedarrayInfo(
        _handle,
        handle,
        kind,
        length,
        data,
        buffer,
        nullptr,
      ),
    );
    if (kind.value != expectedKind) {
      throw ArgumentError(
        'Expected TypedArray kind $expectedKind, received ${kind.value}',
      );
    }
    _checkAttached(buffer.value);
    final bytes = _copyBytes(
      data.value,
      length.value * _typedDataSize(expectedKind),
    );
    return (switch (expectedKind) {
          0 => bytes.buffer.asInt8List(),
          1 => bytes,
          2 => bytes.buffer.asUint8ClampedList(),
          3 => bytes.buffer.asInt16List(),
          4 => bytes.buffer.asUint16List(),
          5 => bytes.buffer.asInt32List(),
          6 => bytes.buffer.asUint32List(),
          7 => bytes.buffer.asFloat32List(),
          8 => bytes.buffer.asFloat64List(),
          9 => bytes.buffer.asInt64List(),
          10 => bytes.buffer.asUint64List(),
          _ => throw ArgumentError(
            'Unsupported TypedArray kind: $expectedKind',
          ),
        })
        as T;
  }

  // ignore: unused_element
  JsObject _writeTypedData(TypedData value, int expectedKind) {
    final length = value.lengthInBytes;
    final buffer = _createArrayBuffer(
      value.buffer.asUint8List(value.offsetInBytes, length),
    );
    return JsObject._(
      this,
      _result(
        (out) => node.napiCreateTypedarray(
          _handle,
          expectedKind,
          length ~/ _typedDataSize(expectedKind),
          buffer,
          0,
          out,
        ),
      ),
      _scope!,
    );
  }

  // ignore: unused_element
  T _readSimdList<T extends TypedData>(JsObject value, int expectedKind) {
    final data = _readTypedData<TypedData>(value, expectedKind);
    if (data.lengthInBytes % 16 != 0) {
      throw ArgumentError('SIMD arrays require a multiple of 16 bytes');
    }
    final offset = data.offsetInBytes;
    final length = data.lengthInBytes ~/ 16;
    return (switch (expectedKind) {
          5 => data.buffer.asInt32x4List(offset, length),
          7 => data.buffer.asFloat32x4List(offset, length),
          8 => data.buffer.asFloat64x2List(offset, length),
          _ => throw ArgumentError('Unsupported SIMD TypedArray kind'),
        })
        as T;
  }

  // ignore: unused_element
  T _readSimd<T>(JsObject value, int expectedKind) {
    final data = _readSimdList<TypedData>(value, expectedKind);
    if (data.lengthInBytes != 16) {
      throw ArgumentError('SIMD vectors require exactly 16 bytes');
    }
    return (switch (expectedKind) {
          5 => (data as Int32x4List)[0],
          7 => (data as Float32x4List)[0],
          8 => (data as Float64x2List)[0],
          _ => throw ArgumentError('Unsupported SIMD TypedArray kind'),
        })
        as T;
  }

  // ignore: unused_element
  JsObject _writeSimd(Object value, int expectedKind) {
    final TypedData data;
    switch (expectedKind) {
      case 5:
        data = Int32x4List(1)..[0] = value as Int32x4;
      case 7:
        data = Float32x4List(1)..[0] = value as Float32x4;
      case 8:
        data = Float64x2List(1)..[0] = value as Float64x2;
      default:
        throw ArgumentError('Unsupported SIMD TypedArray kind');
    }
    return _writeTypedData(data, expectedKind);
  }

  @Available(napi: 6)
  // ignore: unused_element
  T _readBigIntTypedData<T extends TypedData>(
    JsObject value,
    int expectedKind,
  ) => _readTypedData<T>(value, expectedKind);

  @Available(napi: 6)
  // ignore: unused_element
  JsObject _writeBigIntTypedData(TypedData value, int expectedKind) =>
      _writeTypedData(value, expectedKind);

  /// Gets the Dart object carried by a wrapper from this environment.
  ///
  /// The wrapper must have been created by [defineClass]; changing a JavaScript
  /// object's prototype does not make it a Dart instance.
  T unwrap<T extends Object>(JsObject value) {
    value._check();
    if (!identical(value._env, this)) throw ArgumentError('Wrong environment');
    return _unwrap<T>(value._handle);
  }

  T _unwrap<T extends Object>(node.NapiValue handle) =>
      _boundObject<T>(handle).value as T;

  _BoundObject _boundObject<T extends Object>(node.NapiValue handle) {
    final object = _findBoundObject(handle);
    if (object == null || object.value is! T) {
      throw ArgumentError('Invalid $T receiver');
    }
    return object;
  }

  _BoundObject? _findBoundObject(node.NapiValue handle) {
    final valid = _arena<Bool>();
    final status = node.napiCheckObjectTypeTag(_handle, handle, _tag, valid);
    if (status != node.NapiStatus.ok.index || !valid.value) {
      return null;
    }
    final token = _arena<Pointer<Void>>();
    _check(node.napiUnwrap(_handle, handle, token));
    return _objects[token.value.address];
  }

  /// Returns the JavaScript wrapper for a Dart object of a registered class.
  ///
  /// Reuses a live wrapper without running the Dart constructor. If the previous
  /// wrapper was collected, creates another using the registered JS constructor.
  /// A new wrapper requires exactly one [defineClass] registration for T.
  /// Exported subclasses share their most specific registered wrapper.
  /// A live wrapper for an unrelated registered class cannot be reused as T.
  /// `num`, `String`, `bool`, records and FFI values receive independent wrappers.
  JsObject wrap<T extends Object>(T value) => _wrapClass(value, T);

  JsObject _wrapClass(Object value, Type type) {
    if (!_classes.containsKey(type)) {
      throw StateError('No JavaScript class is registered for $type');
    }
    final definition = _classes[type];
    if (definition == null) {
      final existing = _cachedObject(value);
      if (existing != null) return JsObject._(this, existing, _scope!);
      throw StateError(
        'More than one JavaScript class is registered for $type',
      );
    }
    return _wrapObject(value, definition.select(value));
  }

  JsObject _wrapObject(Object value, _ClassDefinition definition) {
    final existing = _cachedObject(value, definition: definition);
    if (existing != null) return JsObject._(this, existing, _scope!);
    final pending = _PendingWrap(value);
    definition.pending.add(pending);
    try {
      final constructor = definition.constructor!.value;
      final handle = _result(
        (out) =>
            node.napiNewInstance(_handle, constructor._handle, 0, nullptr, out),
      );
      return JsObject._(this, handle, _scope!);
    } finally {
      definition.pending.remove(pending);
    }
  }

  // Called after the compiler has registered both classes.
  // ignore: unused_element
  void _inheritClass<T extends Object, S extends Object>() {
    _arena;
    final child = _classes[T];
    final parent = _classes[S];
    if (child == null || parent == null) {
      throw StateError('Inheritance requires uniquely registered classes');
    }
    if (child.parent != null) {
      throw StateError('JavaScript class already has a superclass');
    }
    for (
      _ClassDefinition? ancestor = parent;
      ancestor != null;
      ancestor = ancestor.parent
    ) {
      if (identical(ancestor, child)) {
        throw StateError('JavaScript class inheritance cannot be cyclic');
      }
    }
    final childConstructor = child.constructor!.value;
    final parentConstructor = parent.constructor!.value;
    final object = global.get<JsObject>('Object');
    final setPrototype = object.get<JsFunction>('setPrototypeOf');
    setPrototype.call([
      childConstructor.get<JsObject>('prototype'),
      parentConstructor.get<JsObject>('prototype'),
    ], receiver: object);
    setPrototype.call([childConstructor, parentConstructor], receiver: object);
    child.parent = parent;
    child.hasViews |= parent.hasViews;
    parent.children.add(child);
  }

  // Keeps the ancestor's public contract while converting its type parameters
  // for a concrete descendant receiver.
  // ignore: unused_element
  void _specializeClass<T extends Object, S extends Object>({
    Map<String, Object? Function(T, JsArguments)> methods = const {},
    Map<String, Object? Function(T)> getters = const {},
    Map<String, void Function(T, JsArguments)> setters = const {},
  }) {
    _arena;
    final child = _classes[T];
    final parent = _classes[S];
    if (child == null || parent == null) {
      throw StateError('Specialization requires uniquely registered classes');
    }
    (child.specializations ??= {})[parent] = _ClassSpecialization(
      methods: methods.map(
        (name, body) =>
            MapEntry(name, (value, arguments) => body(value as T, arguments)),
      ),
      getters: getters.map(
        (name, body) => MapEntry(name, (value) => body(value as T)),
      ),
      setters: setters.map(
        (name, body) =>
            MapEntry(name, (value, arguments) => body(value as T, arguments)),
      ),
    );
  }

  // Concrete type arguments share the class's JS constructor and prototype.
  // ignore: unused_element
  void _specializeClassInstance<T extends Object, S extends Object>({
    Map<String, Object? Function(T, JsArguments)> methods = const {},
    Map<String, Object? Function(T)> getters = const {},
    Map<String, void Function(T, JsArguments)> setters = const {},
  }) {
    _arena;
    final definition = _classes[S];
    if (definition == null) {
      throw StateError('No unique JavaScript class for $S');
    }
    if (_classes.containsKey(T) && !identical(_classes[T], definition)) {
      throw StateError('Another JavaScript class is registered for $T');
    }
    if (definition.views?.any((view) => view.type == T) ?? false) return;
    definition.hasViews = true;
    (definition.views ??= []).add(
      _ClassView<T>(
        _ClassSpecialization(
          methods: methods.map(
            (name, body) =>
                MapEntry(name, (value, args) => body(value as T, args)),
          ),
          getters: getters.map(
            (name, body) => MapEntry(name, (value) => body(value as T)),
          ),
          setters: setters.map(
            (name, body) =>
                MapEntry(name, (value, args) => body(value as T, args)),
          ),
        ),
      ),
    );
    _classes[T] = definition;
  }

  node.NapiValue? _cachedObject(Object value, {_ClassDefinition? definition}) {
    // Check the scope even when this object has never been wrapped.
    _arena;
    if (!_cacheableObject(value)) return null;
    final token = _identity[value];
    final object = _objects[token];
    if (object == null) return null;
    final handle = _result(
      (out) => node.napiGetReferenceValue(_handle, object.reference!, out),
    );
    if (handle == nullptr) return null;
    if (definition != null && !identical(object.definition, definition)) {
      throw StateError(
        'Dart object is already bound to another JavaScript class',
      );
    }
    return handle;
  }

  node.NapiValue _bindObject(
    Object value,
    _ClassDefinition definition,
    node.NapiValue self,
    void Function()? finalize,
  ) {
    final existing = _cachedObject(value, definition: definition);
    if (existing != null) return existing;
    node.NapiRef? reference;
    if (_cacheableObject(value)) {
      final out = _arena<node.NapiRef>();
      _check(node.napiCreateReference(_handle, self, 0, out));
      reference = out.value;
      _references.add(reference.address);
    }
    final token = _nextToken++;
    final previous = reference == null ? null : _identity[value];
    try {
      _check(node.napiTypeTagObject(_handle, self, _tag));
      _objects[token] = _BoundObject(value, definition, reference, finalize);
      if (reference != null) _identity[value] = token;
      _check(_runtime.wrap(self, token));
      return self;
    } catch (_) {
      _objects.remove(token);
      if (reference != null) {
        if (_identity[value] == token) _identity[value] = previous;
        _releaseReference(reference.address, check: false);
      }
      rethrow;
    }
  }

  /// Defines a JavaScript class whose instances own Dart objects of type T.
  ///
  /// Static members belong to the constructor rather than its prototype.
  /// Finalizers run after a JS wrapper is collected, or during environment
  /// cleanup. Rewrapping an identity-cached object before its old GC notification
  /// arrives does not finalize the new wrapper. Cleanup finalizers must not
  /// access JavaScript.
  JsFunction defineClass<T extends Object>(
    String name, {
    required T Function(JsArguments) constructor,
    Map<String, Object? Function(T, JsArguments)> methods = const {},
    Map<String, Object? Function(T)> getters = const {},
    Map<String, void Function(T, JsArguments)> setters = const {},
    Map<String, Object? Function(JsArguments)> staticMethods = const {},
    Map<String, Object? Function()> staticGetters = const {},
    Map<String, void Function(JsArguments)> staticSetters = const {},
    void Function(T)? finalize,
  }) {
    final (nativeName, length) = _functionName(name);
    final keys = {...methods.keys, ...getters.keys, ...setters.keys};
    final staticKeys = {
      ...staticMethods.keys,
      ...staticGetters.keys,
      ...staticSetters.keys,
    };
    if (staticKeys.contains('prototype')) {
      throw ArgumentError('Static member prototype is reserved by JavaScript');
    }
    for (final (methodNames, getterNames, setterNames) in [
      (methods.keys, getters.keys, setters.keys),
      (staticMethods.keys, staticGetters.keys, staticSetters.keys),
    ]) {
      for (final key in methodNames) {
        if (getterNames.contains(key) || setterNames.contains(key)) {
          throw ArgumentError('Member $key is both a method and an accessor');
        }
      }
    }
    final definition = _ClassDefinition((value) => value is T);
    final registrations = <int>[];
    int register(node.NapiValue Function(JsArguments, node.NapiValue) body) {
      final token = _nextToken++;
      _callbacks[token] = body;
      registrations.add(token);
      return token;
    }

    final constructorToken = register((arguments, self) {
      final value = definition.pending.isEmpty
          ? constructor(arguments)
          : definition.pending.removeLast().value as T;
      final selected = definition.select(value);
      if (!identical(selected, definition)) {
        return _wrapObject(value, selected)._handle;
      }
      return _bindObject(
        value,
        definition,
        self,
        finalize == null ? null : () => finalize(value),
      );
    });
    final propertyCount = keys.length + staticKeys.length - methods.length;
    final properties = _arena<node.NapiPropertyDescriptor>(
      propertyCount + methods.length,
    );
    var index = 0;
    var methodIndex = propertyCount;
    JsReference<JsFunction>? retained;
    try {
      for (final isStatic in [false, true]) {
        for (final key in isStatic ? staticKeys : keys) {
          final descriptor =
              properties[!isStatic && methods.containsKey(key)
                  ? methodIndex++
                  : index++];
          final attributes =
              node.napiConfigurable | (isStatic ? node.napiStatic : 0);
          descriptor
            ..name = _encode(key)
            ..attributes = attributes;
          if (isStatic
              ? staticMethods.containsKey(key)
              : methods.containsKey(key)) {
            final token = register((args, self) {
              if (isStatic) return _encode(staticMethods[key]!(args));
              final object = _boundObject<T>(self);
              final specialized = object
                  .specialization(definition)
                  ?.methods[key];
              return _encode(
                specialized == null
                    ? methods[key]!(object.value as T, args)
                    : specialized(object.value, args),
              );
            });
            final data = _callbackData(token);
            descriptor.attributes = attributes | node.napiWritable;
            if (isStatic) {
              descriptor
                ..method = _runtime.callback
                ..data = data;
            } else {
              final handle = _result(
                (out) => node.napiCreateFunction(
                  _handle,
                  nullptr,
                  0,
                  _runtime.callback,
                  data,
                  out,
                ),
              );
              _nameFunction(handle, key);
              descriptor.value = handle;
            }
            continue;
          }
          // Getter/setter functions have independent entry points: JS can call an
          // accessor directly with any argument count.
          final token = _nextToken++;
          registrations.add(token);
          descriptor.data = _callbackData(token, accessor: true);
          if (isStatic
              ? staticGetters.containsKey(key)
              : getters.containsKey(key)) {
            _getters[token] = (args, self) {
              if (isStatic) return _encode(staticGetters[key]!());
              final object = _boundObject<T>(self);
              final specialized = object
                  .specialization(definition)
                  ?.getters[key];
              return _encode(
                specialized == null
                    ? getters[key]!(object.value as T)
                    : specialized(object.value),
              );
            };
            descriptor.getter = _runtime.callback;
          }
          if (isStatic
              ? staticSetters.containsKey(key)
              : setters.containsKey(key)) {
            _setters[token] = (args, self) {
              if (isStatic) {
                staticSetters[key]!(args);
              } else {
                final object = _boundObject<T>(self);
                final specialized = object
                    .specialization(definition)
                    ?.setters[key];
                if (specialized == null) {
                  setters[key]!(object.value as T, args);
                } else {
                  specialized(object.value, args);
                }
              }
              return _encode(undefined);
            };
            descriptor.setter = _runtime.setter;
          }
        }
      }
      final handle = _result(
        (out) => node.napiDefineClass(
          _handle,
          nativeName,
          length,
          _runtime.callback,
          _callbackData(constructorToken),
          propertyCount,
          properties,
          out,
        ),
      );
      final function = JsFunction._(this, handle, _scope!);
      if (methods.isNotEmpty) {
        final prototype = function.get<JsObject>('prototype');
        _check(
          node.napiDefineProperties(
            _handle,
            prototype._handle,
            methods.length,
            properties + propertyCount,
          ),
        );
      }
      if (!staticKeys.contains('name')) _nameFunction(handle, name);
      retained = function.retain();
      definition.constructor = retained;
      _classes.update(T, (_) => null, ifAbsent: () => definition);
      // Only this registration requires new; ordinary functions remain callable.
      _constructors.add(constructorToken);
      return function;
    } catch (_) {
      retained?.dispose();
      for (final token in registrations) {
        _callbacks.remove(token);
        _getters.remove(token);
        _setters.remove(token);
      }
      rethrow;
    }
  }

  final _constructors = <int>{};

  // Called by generated top-level property bindings.
  // ignore: unused_element
  void _defineProperty(
    JsObject target,
    String name, {
    Object? Function()? getter,
    void Function(JsArguments)? setter,
  }) {
    target._check();
    if (target._env != this) {
      throw ArgumentError('JavaScript value belongs to another environment');
    }
    final token = _nextToken++;
    try {
      final property = _arena<node.NapiPropertyDescriptor>();
      property.ref
        ..name = _encode(name)
        ..attributes = node.napiEnumerable | node.napiConfigurable
        ..data = _callbackData(token, accessor: true);
      if (getter != null) {
        _getters[token] = (args, self) => _encode(getter());
        property.ref.getter = _runtime.callback;
      }
      if (setter != null) {
        _setters[token] = (args, self) {
          setter(args);
          return _encode(undefined);
        };
        property.ref.setter = _runtime.setter;
      }
      _check(node.napiDefineProperties(_handle, target._handle, 1, property));
    } catch (_) {
      _getters.remove(token);
      _setters.remove(token);
      rethrow;
    }
  }

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
              self.value,
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
        value = out.value;
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
    return _typedValue<T>(value);
  }

  // Reads a value already decoded by a generated composite conversion.
  // ignore: unused_element
  T _typedValue<T>(Object? value) {
    if (value is num) {
      final number = value.toDouble();
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
    }
    if (value is! T) {
      throw ArgumentError('Expected $T, received ${value.runtimeType}');
    }
    return value;
  }

  // Called by compiler-generated bindings.
  // ignore: unused_element
  T _convertObject<T>(T Function() convert) {
    if (_objectDepth >= 128) {
      throw RangeError('Object conversion exceeds 128 nested data objects');
    }
    _objectDepth++;
    try {
      return convert();
    } finally {
      _objectDepth--;
    }
  }

  // Called by compiler-generated bindings.
  // ignore: unused_element
  T _readValue<T>(Object? value) {
    final result = switch (value) {
      JsFunction value => value.retain(),
      JsObject value => value.retain(),
      JsSymbol value => value.retain(),
      _ => value,
    };
    return result as T;
  }

  // A class bound exposes the ordinary wrapper while retaining the callback's
  // actual type argument, which can be a narrower Dart subclass.
  // Only annotated classes participate; low-level registrations of Object or
  // scalar types must not change otherwise opaque generic conversions.
  // ignore: unused_element
  void _registerClassBound<T extends Object>() {
    final bounds = _classBounds ??= {};
    bounds[T] = T;
    bounds[_typeOf<T?>()] = T;
  }

  // ignore: unused_element
  T _readBoundGenericValue<T, B>(Object? value, [_GenericValues? values]) {
    _arena;
    if (!(_classBounds?.containsKey(B) ?? false)) {
      return _readGenericValue<T>(value, values);
    }
    if (value is! JsObject) return _typedValue<T>(value);
    final object = _findBoundObject(_encode(value));
    if (object == null) throw ArgumentError('Expected a bound $B instance');
    return _typedValue<T>(object.value);
  }

  // ignore: unused_element
  Object? _writeBoundGenericValue<T, B>(T value, [_GenericValues? values]) {
    _arena;
    final bound = _classBounds?[B];
    if (bound == null) return _writeGenericValue<T>(value, values);
    return value == null ? null : _wrapClass(value, bound);
  }

  // A whole, otherwise unknown generic type is transferred as an opaque value.
  // ignore: unused_element
  T _readGenericValue<T>(Object? value, [_GenericValues? values]) {
    _arena;
    if (value is JsReference) _encode(value);
    if (value is! _JsValue) return _typedValue<T>(value);
    final handle = _encode(value);
    if (T == JsObject ||
        T == _typeOf<JsObject?>() ||
        T == JsFunction ||
        T == _typeOf<JsFunction?>() ||
        T == JsSymbol ||
        T == _typeOf<JsSymbol?>()) {
      return _typedValue<T>(value);
    }
    final JsReference<_JsValue> reference;
    if ((T == _typeOf<JsReference<JsObject>>() ||
            T == _typeOf<JsReference<JsObject>?>()) &&
        value is JsObject) {
      reference = _retain<JsObject>(value);
    } else if ((T == _typeOf<JsReference<JsFunction>>() ||
            T == _typeOf<JsReference<JsFunction>?>()) &&
        value is JsFunction) {
      reference = _retain<JsFunction>(value);
    } else if ((T == _typeOf<JsReference<JsSymbol>>() ||
            T == _typeOf<JsReference<JsSymbol>?>()) &&
        value is JsSymbol) {
      reference = _retain<JsSymbol>(value);
    } else {
      if (value is JsObject && values != null) {
        final object = _findBoundObject(handle);
        if (object != null &&
            identical(object.definition, _classes[_GenericPayload]) &&
            object.value is _GenericPayload &&
            !(values.origins?.contains(object) ?? false)) {
          return _typedValue<T>((object.value as _GenericPayload).value);
        }
      }
      reference = switch (value) {
        JsFunction value => value.retain(),
        JsObject value => value.retain(),
        JsSymbol value => value.retain(),
        _ => throw ArgumentError('Unsupported JavaScript value'),
      };
    }
    try {
      return _typedValue<T>(reference);
    } catch (_) {
      reference.dispose();
      rethrow;
    }
  }

  // ignore: unused_element
  Object? _writeGenericValue<T>(T value, [_GenericValues? values]) {
    _arena;
    if (value == null ||
        value is bool ||
        value is num ||
        value is String ||
        value is BigInt ||
        identical(value, undefined)) {
      return value;
    }
    if (value is _JsValue || value is JsReference) {
      final handle = _encode(value);
      if (values != null) {
        final object = _findBoundObject(handle);
        if (object != null &&
            identical(object.definition, _classes[_GenericPayload]) &&
            object.value is _GenericPayload) {
          (values.origins ??= {}).add(object);
        }
      }
      return value;
    }
    if (!_classes.containsKey(_GenericPayload)) {
      defineClass<_GenericPayload>(
        'DartValue',
        constructor: (_) =>
            throw StateError('Opaque Dart values cannot be constructed'),
      );
    }
    final _GenericPayload payload;
    if (_cacheableObject(value)) {
      payload = _genericPayloads[value] ??= _GenericPayload(value);
    } else {
      payload = _GenericPayload(value);
    }
    return wrap(payload);
  }

  node.NapiValue _encode(Object? value) {
    if (value == null) return _result((out) => node.napiGetNull(_handle, out));
    if (identical(value, undefined)) {
      return _result((out) => node.napiGetUndefined(_handle, out));
    }
    if (value is JsReference) {
      if (!identical(value._env, this)) {
        throw ArgumentError(
          'JavaScript reference belongs to another environment',
        );
      }
      return _encode(value.value);
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

  node.NapiValue _errorValue(Object error) {
    if (error is JsException) {
      return _encode(error.value);
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
    return exception;
  }

  void _throw(Object error) => node.napiThrow(_handle, _errorValue(error));

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
    if (_callbacks.remove(token) != null) {
      final function = _functions.remove(token);
      if (function != null) {
        _releaseReference(function.reference.address, check: false);
        final signatures = _functionIdentity[function.value];
        if (signatures?[function.signature] == token) {
          signatures!.remove(function.signature);
          if (signatures.isEmpty) _functionIdentity[function.value] = null;
        }
      }
      return;
    }
    final object = _objects.remove(token);
    if (object == null) return;
    final reference = object.reference;
    if (reference != null) {
      _releaseReference(reference.address, check: false);
      if (_identity[object.value] != token) return;
      _identity[object.value] = null;
    }
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
    final objects = _objects.entries.toList();
    _objects.clear();
    _classes.clear();
    _classBounds?.clear();
    _functions.clear();
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
    for (final entry in objects) {
      final object = entry.value;
      if (object.reference != null) {
        if (_identity[object.value] != entry.key) continue;
        _identity[object.value] = null;
      }
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

// Distinguishes an omitted optional callback argument from null and undefined.
// ignore: unused_element
const _omittedArgument = _OmittedArgument();

final class _OmittedArgument {
  const _OmittedArgument();
}

int _typedDataSize(int kind) => switch (kind) {
  0 || 1 || 2 => 1,
  3 || 4 => 2,
  5 || 6 || 7 => 4,
  8 || 9 || 10 => 8,
  _ => throw ArgumentError('Unsupported TypedArray kind: $kind'),
};

bool _cacheableObject(Object value) =>
    value is! num &&
    value is! String &&
    value is! bool &&
    value is! Record &&
    value is! Pointer &&
    value is! Struct &&
    value is! Union;
