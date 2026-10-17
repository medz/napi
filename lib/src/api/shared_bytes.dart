import 'dart:typed_data';

import '../runtime/shared_bytes.dart' show allocateSharedBytes;

/// A live JavaScript Uint8Array window, retained while this object is reachable.
///
/// Unlike ordinary Uint8List bindings, this type shares mutations. Each access
/// checks the current window; detached and out-of-bounds views throw. Resizable
/// ArrayBuffers are supported, but SharedArrayBuffers are not.
abstract interface class SharedBytes {
  /// Allocates a zero-filled, fixed-size host buffer in the current module.
  /// Requires an initialized generated binding and an active runtime owner.
  factory SharedBytes.allocate(int length) => allocateSharedBytes(length);

  int get length;
  int operator [](int index);
  void operator []=(int index, int value);

  /// Returns a shared, fixed-length view of [start] through [end] (exclusive).
  SharedBytes subview(int start, [int? end]);

  /// Copies the selected current window into an independent Dart byte list.
  Uint8List toUint8List([int start = 0, int? end]);

  /// Copies [source] into this window starting at [offset].
  void write(Uint8List source, {int offset = 0});

  /// Copies a current source window; overlapping ranges behave like memmove.
  void copyFrom(
    SharedBytes source, {
    int sourceOffset = 0,
    int targetOffset = 0,
    int? length,
  });
}
