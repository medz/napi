import 'dart:io';

import 'package/artifact.dart';

/// An output to build from Dart source or native artifacts.
sealed class Target {
  const Target();
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
    required this.entry,
    required this.output,
    this.node,
    this.declarations,
  });

  /// The Dart library to compile.
  final File entry;

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

/// An npm package with native bindings, CJS/ESM entries and TypeScript types.
///
/// Builds the current platform. Use [PackageBuild.fromArtifacts] to assemble
/// previously built native artifacts without invoking the bundled compiler.
final class PackageBuild extends Target {
  PackageBuild({
    required File entry,
    required this.output,
    required this.name,
    required this.version,
    this.node,
    // ignore: prefer_initializing_formals
  }) : entry = entry,
       artifacts = const [];

  PackageBuild.fromArtifacts({
    required List<NativeArtifact> artifacts,
    required this.output,
    required this.name,
    required this.version,
  }) : entry = null,
       node = null,
       artifacts = List.unmodifiable(artifacts);

  /// The annotated Dart library, or null when assembling artifacts.
  final File? entry;

  /// Native artifact manifests to assemble. Empty for source builds.
  final List<NativeArtifact> artifacts;

  /// The generated package directory.
  final Directory output;

  /// The npm package name, including its optional scope.
  final String name;

  /// The npm package's semantic version.
  final String version;

  /// An optional Node.js compatibility range for a source build.
  final String? node;
}
