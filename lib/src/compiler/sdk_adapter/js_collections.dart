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
external WasmExternRef _jcTypeError();

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
JSAny _writeJsCollection(Object value, String signature) {
  if (value is! _JsCollection || value.signature != signature) throw _CallbackThrown(_jcTypeError());
  return value.source!.toJS;
}
abstract class _JsCollection {
  final WasmExternRef? source;
  final String signature;
  _JsCollection(WasmExternRef source, this.signature) : source = source;
  JSAny? invoke(int op, [JSAny? a, JSAny? b]) {
    final envelope = _jcCall(source!, externRefForJSAny(signature.toJS)!, WasmI32.fromInt(op), _jcRef(a), _jcRef(b));
    if (_jcThrew(envelope).toIntSigned() != 0) throw _CallbackThrown(envelope);
    return _jcJS(_jcValue(envelope));
  }
}
final class _JsArray<T> extends _JsCollection implements napi.JsArray<T> {
  final T Function(JSAny?) read;
  final JSAny? Function(T) write;
  _JsArray(super.source, super.signature, this.read, this.write);
  @override
  int get length => (invoke(1) as JSNumber).toDartInt;
  @override
  T? get(int index) { final value = invoke(2, index.toJS); return value == null ? null : read(value); }
  @override
  void set(int index, T value) { invoke(3, index.toJS, write(value)); }
}
final class _JsMap<K,V> extends _JsCollection implements napi.JsMap<K,V> {
  final K Function(JSAny?) readKey;
  final JSAny? Function(K) writeKey;
  final V Function(JSAny?) readValue;
  final JSAny? Function(V) writeValue;
  _JsMap(super.source, super.signature, this.readKey, this.writeKey, this.readValue, this.writeValue);
  @override
  int get size => (invoke(1) as JSNumber).toDartInt;
  @override
  bool has(K key) => (invoke(4, writeKey(key)) as JSBoolean).toDart;
  @override
  V? get(K key) { final value = invoke(2, writeKey(key)); return value == null ? null : readValue(value); }
  @override
  void set(K key, V value) { invoke(3, writeKey(key), writeValue(value)); }
  @override
  bool delete(K key) => (invoke(5, writeKey(key)) as JSBoolean).toDart;
  @override
  void clear() { invoke(6); }
  @override
  Iterable<(K,V)> get entries sync* {
    final iterator = invoke(7);
    while (true) {
      // The owner is an observable host argument on every step, retaining it.
      final entry = invoke(8, iterator);
      if (entry == null) return;
      final raw = externRefForJSAny(entry)!;
      yield (readKey(_jcJS(_jcField(raw, WasmI32.fromInt(0)))), readValue(_jcJS(_jcField(raw, WasmI32.fromInt(1)))));
    }
  }
}
''';
