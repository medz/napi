import 'dart:io';

/// A compilation target for a Dart library.
sealed class Target {
  const Target({required this.entry});

  /// The Dart library to compile.
  final File entry;
}

/// A native Node-API addon to compile.
///
/// Uses the bundled compiler and runtime for the current platform. The entry
/// must provide the low-level initialize/afterPump/dispose hooks; automatic
/// exports from ordinary Dart declarations are not implemented yet.
///
/// Uses Node's default per-module API behavior. The [node] constraint checks API
/// availability; it does not opt into newer per-module API behavior.
final class NativeTarget extends Target {
  const NativeTarget({required super.entry, required this.output, this.node});

  /// The output `.node` file.
  final File output;

  /// An optional Node.js compatibility version range.
  ///
  /// Uses Dart version constraint syntax, with `||` for alternatives. Omit this
  /// to infer requirements from the APIs used by the addon.
  final String? node;
}
