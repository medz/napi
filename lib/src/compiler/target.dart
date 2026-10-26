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
/// generates bindings for annotated functions and classes. It also accepts
/// `void register(Env env, JsObject exports)` or the low-level
/// initialize/afterPump/dispose hooks for explicit registration.
///
/// Uses Node's default per-module API behavior. The [node] constraint checks API
/// availability; it does not opt into newer per-module API behavior.
final class NativeTarget extends Target {
  const NativeTarget({
    required super.entry,
    required this.output,
    this.node,
    this.declarations,
  });

  /// The output `.node` file.
  final File output;

  /// An optional `.d.ts` output for annotation-based exports.
  ///
  /// Omit this to produce only the native binary. Raw entry hooks do not carry
  /// enough information to generate declarations.
  final File? declarations;

  /// An optional Node.js compatibility version range.
  ///
  /// Uses Dart version constraint syntax, with `||` for alternatives. Omit this
  /// to infer requirements from the APIs used by the addon.
  final String? node;
}
