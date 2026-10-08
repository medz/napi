import 'dart:js_interop';
import 'dart:typed_data';

import 'api.dart' as api;

@JS('dartBaseline')
external set _baseline(_Api value);

@JS()
extension type _Api._(JSObject _) implements JSObject {
  external factory _Api({
    required JSFunction add,
    required JSFunction identityInt,
    required JSFunction echoString,
    required JSFunction stringLength,
    required JSFunction echoBytes,
    required JSFunction sumBytes,
    required JSFunction addAsync,
    required JSFunction echoStringAsync,
    required JSFunction echoBytesAsync,
  });
}

JSNumber _add(JSNumber a, JSNumber b) =>
    api.add(a.toDartDouble, b.toDartDouble).toJS;
JSNumber _identityInt(JSNumber value) => api.identityInt(value.toDartInt).toJS;
JSString _echoString(JSString value) => api.echoString(value.toDart).toJS;
JSNumber _stringLength(JSString value) => api.stringLength(value.toDart).toJS;
JSUint8Array _echoBytes(JSUint8Array value) =>
    Uint8List.fromList(api.echoBytes(Uint8List.fromList(value.toDart))).toJS;
JSNumber _sumBytes(JSUint8Array value) =>
    api.sumBytes(Uint8List.fromList(value.toDart)).toJS;
JSPromise<JSNumber> _addAsync(JSNumber a, JSNumber b) =>
    api.addAsync(a.toDartDouble, b.toDartDouble).then((v) => v.toJS).toJS;
JSPromise<JSString> _echoStringAsync(JSString value) =>
    api.echoStringAsync(value.toDart).then((v) => v.toJS).toJS;
JSPromise<JSUint8Array> _echoBytesAsync(JSUint8Array value) => api
    .echoBytesAsync(Uint8List.fromList(value.toDart))
    .then((v) => Uint8List.fromList(v).toJS)
    .toJS;

void main() {
  _baseline = _Api(
    add: _add.toJS,
    identityInt: _identityInt.toJS,
    echoString: _echoString.toJS,
    stringLength: _stringLength.toJS,
    echoBytes: _echoBytes.toJS,
    sumBytes: _sumBytes.toJS,
    addAsync: _addAsync.toJS,
    echoStringAsync: _echoStringAsync.toJS,
    echoBytesAsync: _echoBytesAsync.toJS,
  );
}
