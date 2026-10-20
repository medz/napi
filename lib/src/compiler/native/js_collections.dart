part of 'bindings.dart';

final class NativeJsElement<T> {
  final String kind;
  final bool nullable;
  final bool bigint;
  final T Function(NapiApi, Pointer<Void>, Pointer<Void>, String)? readHandle;
  final int Function(NapiApi, Pointer<Void>, T, String)? writeHandle;
  const NativeJsElement(
    this.kind, {
    this.nullable = false,
    this.bigint = false,
    this.readHandle,
    this.writeHandle,
  });
  T read(NapiApi api, Pointer<Void> env, Pointer<Void> value, String path) {
    if (kind == 'opaque') return api.ownHostValue(env, value) as T;
    if (nullable && api.isNull(env, value)) return null as T;
    if (readHandle case final read?) return read(api, env, value, path);
    return switch (kind) {
      'boolean' => api.boolean(env, value, path),
      'string' => api.string(env, value, path),
      'integer' =>
        bigint
            ? api.integerBigInt(env, value, path)
            : api.integer(env, value, path),
      'doubleValue' => api.doubleValue(env, value, path),
      'bigInteger' => api.bigInteger(env, value, path),
      _ => throw StateError('Unknown JS collection element'),
    } as T;
  }

  T? readGet(NapiApi api, Pointer<Void> env, Pointer<Void> value, String path) {
    if (api.isNull(env, value)) return null;
    return read(
      api,
      env,
      kind == 'opaque' ? api.readOwnValue(env, value, '0', path) : value,
      path,
    );
  }

  int write(NapiApi api, Pointer<Void> env, T value, String path) {
    if (nullable && value == null) return api.nullResult(env);
    if (writeHandle case final write?) return write(api, env, value, path);
    return switch (kind) {
      'opaque' => api.hostValue(env, value as NativeHostValue).address,
      'boolean' => api.booleanResult(env, value as bool),
      'string' => api.stringResult(env, value as String),
      'integer' =>
        bigint
            ? api.integerBigIntResult(env, value as int)
            : api.integerResult(env, value as int, path),
      'doubleValue' => api.doubleResult(env, value as double),
      'bigInteger' => api.bigIntegerResult(env, value as BigInt),
      _ => throw StateError('Unknown JS collection element'),
    };
  }
}

abstract class _NativeJsCollection {
  final NapiApi api;
  final Pointer<Void> env;
  final NativeHostValue source;
  final String signature;
  _NativeJsCollection(this.api, this.env, this.source, this.signature);
  R invoke<R>(
    int op,
    int Function(Pointer<Void>)? a,
    int Function(Pointer<Void>)? b,
    R Function(Pointer<Void>, Pointer<Void>) read,
  ) => api._jsCollectionCall(env, source, signature, op, a, b, read);
  int get count => invoke(
    1,
    null,
    null,
    (env, value) => api.integer(env, value, 'JS collection length'),
  );
}

final class _NativeJsArray<T> extends _NativeJsCollection
    implements JsArray<T> {
  final NativeJsElement<T> scalar;
  _NativeJsArray(
    super.api,
    super.env,
    super.source,
    super.signature,
    this.scalar,
  );
  @override
  int get length => count;
  @override
  T? get(int index) => invoke(
    2,
    (env) => api.integerResult(env, index, 'JsArray index'),
    null,
    (env, value) => scalar.readGet(api, env, value, 'JsArray value'),
  );
  @override
  void set(int index, T value) => invoke<void>(
    3,
    (env) => api.integerResult(env, index, 'JsArray index'),
    (env) => scalar.write(api, env, value, 'JsArray value'),
    (_, _) {},
  );
}

final class _NativeJsMap<K, V> extends _NativeJsCollection
    implements JsMap<K, V> {
  final NativeJsElement<K> key;
  final NativeJsElement<V> value;
  _NativeJsMap(
    super.api,
    super.env,
    super.source,
    super.signature,
    this.key,
    this.value,
  );
  int _key(Pointer<Void> env, K item) => key.write(api, env, item, 'JsMap key');
  @override
  int get size => count;
  @override
  bool has(K item) => invoke(
    4,
    (env) => _key(env, item),
    null,
    (env, value) => api.boolean(env, value, 'JsMap has'),
  );
  @override
  V? get(K item) => invoke(
    2,
    (env) => _key(env, item),
    null,
    (env, raw) => value.readGet(api, env, raw, 'JsMap value'),
  );
  @override
  void set(K item, V entry) => invoke<void>(
    3,
    (env) => _key(env, item),
    (env) => value.write(api, env, entry, 'JsMap value'),
    (_, _) {},
  );
  @override
  bool delete(K item) => invoke(
    5,
    (env) => _key(env, item),
    null,
    (env, value) => api.boolean(env, value, 'JsMap delete'),
  );
  @override
  void clear() => invoke<void>(6, null, null, (_, _) {});
  @override
  Iterable<(K, V)> get entries sync* {
    final iterator = invoke(7, null, null, api.ownHostValue);
    try {
      while (true) {
        final entry = invoke<(K, V)?>(
          8,
          (env) => api.hostValue(env, iterator).address,
          null,
          (env, raw) => api.isNull(env, raw)
              ? null
              : (
                  key.read(
                    api,
                    env,
                    api.readOwnValue(env, raw, '0', 'JsMap entry'),
                    'JsMap key',
                  ),
                  value.read(
                    api,
                    env,
                    api.readOwnValue(env, raw, '1', 'JsMap entry'),
                    'JsMap value',
                  ),
                ),
        );
        if (entry == null) return;
        yield entry;
      }
    } finally {
      iterator.release();
    }
  }
}

final class _NativeJsEntry {
  final WeakReference<_NativeJsCollection> target;
  _NativeJsEntry(_NativeJsCollection value) : target = WeakReference(value);
}

extension NativeJsBindings on NapiApi {
  R _jsCollectionCall<R>(
    Pointer<Void> env,
    NativeHostValue source,
    String signature,
    int operation,
    int Function(Pointer<Void>)? a,
    int Function(Pointer<Void>)? b,
    R Function(Pointer<Void>, Pointer<Void>) read,
  ) => _invokeCallback(env, _getCallbackHelper(env, 0), 6, (env, args) {
    _borrowHostValue(env, source, args);
    args[1] = Pointer.fromAddress(integerResult(env, 4, 'operation'));
    args[2] = Pointer.fromAddress(stringResult(env, signature));
    args[3] = Pointer.fromAddress(integerResult(env, operation, 'operation'));
    args[4] = Pointer.fromAddress(a == null ? nullResult(env) : a(env));
    args[5] = Pointer.fromAddress(b == null ? nullResult(env) : b(env));
  }, read);

  C _jsCollection<C extends _NativeJsCollection>(
    Pointer<Void> env,
    Pointer<Void> value,
    String signature,
    String path,
    C Function(NativeHostValue) create,
  ) => _invokeCallback(
    env,
    _getCallbackHelper(env, 0),
    6,
    (env, args) {
      args[0] = value;
      args[1] = Pointer.fromAddress(integerResult(env, 4, 'operation'));
      args[2] = Pointer.fromAddress(stringResult(env, signature));
      args[3] = Pointer.fromAddress(integerResult(env, 0, 'operation'));
      args[4] = Pointer.fromAddress(stringResult(env, path));
      args[5] = Pointer.fromAddress(nullResult(env));
    },
    (env, raw) {
      final id = (_hostIdentity(env, raw), signature);
      final previous = _jsCollections[id]?.target.target;
      if (previous != null) return previous as C;
      final source = ownHostValue(env, raw);
      try {
        final adapter = create(source);
        final entry = _NativeJsEntry(adapter);
        _jsCollections[id] = entry;
        _jsCollectionFinalizer.attach(adapter, (id, entry));
        return adapter;
      } catch (_) {
        source.release();
        rethrow;
      }
    },
  );

  JsArray<T> jsArray<T>(
    Pointer<Void> env,
    Pointer<Void> value,
    String signature,
    String path,
    NativeJsElement<T> scalar,
  ) => _jsCollection<_NativeJsArray<T>>(
    env,
    value,
    signature,
    path,
    (source) => _NativeJsArray(this, env, source, signature, scalar),
  );
  JsMap<K, V> jsMap<K, V>(
    Pointer<Void> env,
    Pointer<Void> value,
    String signature,
    String path,
    NativeJsElement<K> key,
    NativeJsElement<V> scalar,
  ) => _jsCollection<_NativeJsMap<K, V>>(
    env,
    value,
    signature,
    path,
    (source) => _NativeJsMap(this, env, source, signature, key, scalar),
  );
  int jsCollectionResult(
    Pointer<Void> env,
    Object value,
    String signature,
    String path,
  ) {
    if (value is! _NativeJsCollection ||
        !identical(value.api, this) ||
        value.env != env ||
        value.signature != signature) {
      throw NapiTypeError(
        '$path: expected a JS collection handle with this module and element policy',
      );
    }
    return hostValue(env, value.source).address;
  }
}
