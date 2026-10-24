import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as path;

import '../compiler/analysis/validate.dart';
import '../compiler/front_end/external.dart';
import '../compiler/sdk_adapter/dart_sdk_adapter.dart';
import 'build.dart';
import 'package.dart';
import 'watch.dart';

/// A reusable npm package declaration for a user-defined Dart build script.
///
/// Call [build] from Dart code, or pass the script's arguments to [run] for
/// command-line help and per-invocation output and backend selection. Relative
/// paths use the working directory, as in ordinary Dart file operations.
final class PackageBuild {
  PackageBuild({
    required this.library,
    required this.output,
    required this.name,
    required this.version,
    Map<String, Object?> metadata = const {},
    Map<String, File> assets = const {},
    this.packagesPath,
    this.external,
    this.target = BuildTarget.wasm,
    Set<BuildTarget>? targets,
    this.nativeRuntime,
  }) : metadata = Map.unmodifiable(metadata),
       assets = Map.unmodifiable(assets),
       targets = targets == null ? null : Set.unmodifiable(targets);

  final Uri library;
  final Directory output;
  final String name;
  final String version;

  /// Additional npm fields. Supply name and version through their typed fields.
  final Map<String, Object?> metadata;
  final Map<String, File> assets;
  final String? packagesPath;
  final ExternalLibrary? external;
  final BuildTarget target;
  final Set<BuildTarget>? targets;
  final Directory? nativeRuntime;

  /// Build once with the declared options. Build failures propagate to the caller.
  Future<Directory> build() => _build(output, target, targets, nativeRuntime);

  Future<Directory> _build(
    Directory destination,
    BuildTarget root,
    Set<BuildTarget>? selected,
    Directory? runtime,
  ) async {
    for (final field in ['name', 'version']) {
      if (metadata.containsKey(field)) {
        throw ArgumentError(
          'Supply "$field" through PackageBuild.$field, not metadata.',
        );
      }
    }
    return buildPackage(
      library: library,
      output: destination,
      metadata: {...metadata, 'name': name, 'version': version},
      assets: assets,
      packagesPath: packagesPath,
      external: external,
      target: root,
      targets: selected,
      nativeRuntime: runtime,
    );
  }

  /// Run this declaration as the calling script's command-line interface.
  ///
  /// Options only affect this invocation. Expected failures print a diagnostic
  /// and set [exitCode] to 64 for invalid arguments or 1 for build failures;
  /// this method does not terminate the process. Use [build] to handle errors
  /// directly. Selecting Wasm alone does not access the native runtime.
  Future<void> run(List<String> arguments) async {
    final parser = ArgParser()
      ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage.')
      ..addFlag(
        'watch',
        negatable: false,
        help: 'Rebuild when Dart sources or package assets change.',
      )
      ..addOption(
        'target',
        allowed: ['wasm', 'native', 'both'],
        help: 'Select backends for this build. Both retains the declared root.',
      )
      ..addOption(
        'output',
        abbr: 'o',
        help: 'Override the output directory for this build.',
      );
    try {
      final options = parser.parse(arguments);
      if (options.rest.isNotEmpty) {
        throw FormatException(
          'Unexpected arguments: ${options.rest.join(' ')}',
        );
      }
      if (options.flag('help')) {
        final script = path.relative(Platform.script.toFilePath());
        stdout.writeln('Usage: dart run $script [options]\n\n${parser.usage}');
        return;
      }
      final override = options.option('target');
      final root = switch (override) {
        'wasm' => BuildTarget.wasm,
        'native' => BuildTarget.native,
        _ => target,
      };
      final selected = switch (override) {
        'both' => BuildTarget.values.toSet(),
        'wasm' || 'native' => {root},
        _ => targets,
      };
      final destination = options.option('output');
      if (destination != null && destination.isEmpty) {
        throw const FormatException('Output directory must not be empty.');
      }
      final directory = destination == null ? output : Directory(destination);
      Future<void> buildOnce() async {
        final result = await _build(
          directory,
          root,
          selected,
          override == 'wasm' ? null : nativeRuntime,
        );
        stdout.writeln('Built ${result.path}');
      }

      if (!options.flag('watch')) {
        await buildOnce();
        return;
      }
      if (Platform.isWindows) {
        throw UnsupportedError(
          'Watch mode requires managed output replacement, which is not yet '
          'supported on Windows.',
        );
      }
      final stop = StreamController<void>();
      final signals = [
        for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm])
          signal.watch().listen((_) => stop.add(null)),
      ];
      try {
        await watchBuild(
          library: library,
          output: directory,
          packagesPath: libraryPackagesPath(packagesPath, external),
          assets: assets.values,
          stop: stop.stream,
          build: () async {
            try {
              await buildOnce();
              exitCode = 0;
            } catch (error) {
              if (!_report(error)) rethrow;
            }
          },
        );
      } finally {
        for (final signal in signals) {
          await signal.cancel();
        }
        await stop.close();
      }
    } catch (error) {
      if (!_report(error)) rethrow;
    }
  }
}

bool _report(Object error) {
  final (String message, int code) = switch (error) {
    FormatException() => ('napi: ${error.message}', 64),
    ArgumentError() => ('napi: ${error.message}', 64),
    BindingDiagnostic() => ('$error', 1),
    SdkCompatibilityException() ||
    IOException() ||
    TimeoutException() => ('napi: $error', 1),
    StateError() => ('napi: ${error.message}', 1),
    UnsupportedError() => ('napi: ${error.message}', 1),
    _ => ('', 0),
  };
  if (code == 0) return false;
  stderr.writeln(message);
  exitCode = code;
  return true;
}
