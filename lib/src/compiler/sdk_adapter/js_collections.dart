/// Retained externref handles, with weak identity and no JS facade.
const jsCollectionsEntrypointPrelude = r'''
@pragma('wasm:import', 'napi.jsCollectionCall')
external WasmExternRef _jcCall(WasmExternRef source, WasmExternRef signature, WasmI32 op, WasmExternRef? a, WasmExternRef? b);
@pragma('wasm:import', 'napi.jsCollectionThrew')
external WasmI32 _jcThrew(WasmExternRef envelope);
@pragma('wasm:import', 'napi.jsCollectionValue')
external WasmExternRef? _jcValue(WasmExternRef envelope);
@pragma('wasm:import', 'napi.jsCollectionField')
external WasmExternRef? _jcField(WasmExternRef entry, WasmI32 index);
@pragma('wasm:import', 'napi.jsCollectionFind')
external WasmExternRef? _jcFind(WasmExternRef source, WasmExternRef signature);
@pragma('wasm:import', 'napi.jsCollectionCache')
external void _jcCache(WasmExternRef source, WasmExternRef signature, WasmExternRef adapter);
@pragma('wasm:import', 'napi.jsCollectionTypeError')
external WasmExternRef _jcTypeError(WasmExternRef? message, WasmI32 range);

JSAny? _jcJS(WasmExternRef? value) => value.isNull ? null : value!.toJS;
WasmExternRef? _jcRef(JSAny? value) => value == null ? WasmExternRef.nullRef : externRefForJSAny(value);
T _jcAdapter<T extends Object>(WasmExternRef source, String signature, T Function() create) {
  final key = externRefForJSAny(signature.toJS)!;
  final previous = _jcFind(source, key);
  if (!previous.isNull) return previous!.internalize().toObject() as T;
  final adapter = create();
  _jcCache(source, key, WasmAnyRef.fromObject(adapter).externalize());
  return adapter;
}
JSAny _writeJsCollection(Object value, String signature, {bool defer = false}) {
  if (value is! _JsCollection || value.signature != signature) {
    // False cannot be a valid Array/Map handle. Nested host validation rejects
    // this private value only after all Dart snapshot getters have completed.
    if (defer) return false.toJS;
    throw _CallbackThrown(_jcTypeError(WasmExternRef.nullRef, WasmI32.fromInt(0)));
  }
  return value.source!.toJS;
}
abstract class _JsCollection {
  final WasmExternRef? source;
  final String signature;
  _JsCollection(WasmExternRef source, this.signature) : source = source;
  WasmExternRef? invoke(int op, WasmExternRef? a, WasmExternRef? b) {
    final envelope = _jcCall(source!, externRefForJSAny(signature.toJS)!, WasmI32.fromInt(op), a, b);
    if (_jcThrew(envelope).toIntSigned() != 0) throw _CallbackThrown(envelope);
    return _jcValue(envelope);
  }
}
// Raw externref cannot cross a Dart Function invocation in the pinned SDK.
// Direct methods keep opaque fields raw; typed closures use JS interop.
final class _JsElement<T> {
  final bool opaque;
  final T Function(JSAny?)? readValue;
  final JSAny? Function(T)? writeValue;
  const _JsElement(this.opaque, this.readValue, this.writeValue);
  T read(WasmExternRef? value) => opaque
      ? _NapiHostValue(value) as T
      : readValue!(_jcJS(value));
  WasmExternRef? write(T value) => opaque
      ? value == null ? WasmExternRef.nullRef : (value as _NapiHostValue).value
      : _jcRef(writeValue!(value));
  T? readGet(WasmExternRef? value) => value.isNull ? null
      : read(opaque ? _jcField(value!, WasmI32.fromInt(0)) : value);
}
final class _JsArray<T> extends _JsCollection implements napi.JsArray<T> {
  final _JsElement<T> element;
  _JsArray(super.source, super.signature, this.element);
  @override
  int get length => (invoke(1, WasmExternRef.nullRef, WasmExternRef.nullRef)!.toJS as JSNumber).toDartInt;
  @override
  T? get(int index) => element.readGet(invoke(2, _jcRef(index.toJS), WasmExternRef.nullRef));
  @override
  void set(int index, T value) { invoke(3, _jcRef(index.toJS), element.write(value)); }
}
final class _JsMap<K,V> extends _JsCollection implements napi.JsMap<K,V> {
  final _JsElement<K> key;
  final _JsElement<V> value;
  _JsMap(super.source, super.signature, this.key, this.value);
  @override
  int get size => (invoke(1, WasmExternRef.nullRef, WasmExternRef.nullRef)!.toJS as JSNumber).toDartInt;
  @override
  bool has(K item) => (invoke(4, key.write(item), WasmExternRef.nullRef)!.toJS as JSBoolean).toDart;
  @override
  V? get(K item) => value.readGet(invoke(2, key.write(item), WasmExternRef.nullRef));
  @override
  void set(K item, V entry) { invoke(3, key.write(item), value.write(entry)); }
  @override
  bool delete(K item) => (invoke(5, key.write(item), WasmExternRef.nullRef)!.toJS as JSBoolean).toDart;
  @override
  void clear() { invoke(6, WasmExternRef.nullRef, WasmExternRef.nullRef); }
  (K,V) readEntry(JSAny entry) {
    final raw = externRefForJSAny(entry)!;
    return (key.read(_jcField(raw, WasmI32.fromInt(0))), value.read(_jcField(raw, WasmI32.fromInt(1))));
  }
  @override
  Iterable<(K,V)> get entries sync* {
    final iterator = invoke(7, WasmExternRef.nullRef, WasmExternRef.nullRef)!.toJS;
    while (true) {
      // The owner is an observable host argument on every step, retaining it.
      final entry = _jcJS(invoke(8, _jcRef(iterator), WasmExternRef.nullRef));
      if (entry == null) return;
      yield readEntry(entry);
    }
  }
}
''';

/// Resource checks are independent of the operation active during a lazy read.
const jsCollectionsResourceEntrypointPrelude = r'''
void _jcRetainResource(Object? value, String path) {
  try {
    final control = _resourceControl(value);
    if (control == null) return;
    final operation = ResourceOperation.current;
    if (operation == null) {
      throw _CallbackThrown(_jcTypeError(externRefForJSAny((path + ': resource access requires an active bound call').toJS), WasmI32.fromInt(0)));
    }
    operation.retain(control);
  } on _ResourcePolicyViolation {
    throw _CallbackThrown(_jcTypeError(externRefForJSAny((path + ': incompatible resource cleanup policies').toJS), WasmI32.fromInt(0)));
  }
}
''';
