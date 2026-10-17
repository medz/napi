import '../api/shared_bytes.dart';

SharedBytes Function(int)? _allocate;

/// Installs the generated module's private allocator once during startup.
void installSharedBytesAllocator(SharedBytes Function(int) allocate) {
  _allocate ??= allocate;
}

/// Internal entry used by the public factory; not exported by runtime.dart.
SharedBytes allocateSharedBytes(int length) {
  final allocate = _allocate;
  if (allocate == null) {
    throw StateError(
      'SharedBytes.allocate requires an initialized napi module',
    );
  }
  return allocate(length);
}
