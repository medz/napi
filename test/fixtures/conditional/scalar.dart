// Transitive conditional export: the frontend must match dart compile wasm.
export 'fallback.dart' if (dart.library.js_interop) 'wasm.dart';
