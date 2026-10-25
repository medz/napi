import 'dart:io';

/// A compilation target for a Dart library.
sealed class Target {
  const Target({required this.entry});

  /// The Dart library to compile.
  final File entry;
}

/// A native Node-API addon to compile.
///
/// Uses the precompiled runtime template for the current platform. The entry
/// must provide the low-level initialize/afterPump/dispose hooks; automatic
/// exports from ordinary Dart declarations are not implemented yet.
final class NativeTarget extends Target {
  const NativeTarget({required super.entry, required this.output, this.node});

  /// The output `.node` file.
  final File output;

  /// An optional Node.js compatibility version range.
  ///
  /// Compatibility analysis is not implemented yet; non-null values are rejected.
  final String? node;
}
