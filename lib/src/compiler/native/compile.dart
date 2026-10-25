import 'dart:io';

import '../sdk.dart';
import '../target.dart';
import 'bindings.dart';
import 'template.dart';

/// Compiles an internal embedder entry to a self-contained native addon.
Future<void> compileNative(NativeTarget target) async {
  final source = target.entry.absolute;
  final output = target.output.absolute;
  if (!source.existsSync()) {
    throw ArgumentError('Entry does not exist: ${source.path}');
  }
  if (!output.path.endsWith('.node')) {
    throw ArgumentError('Native output must be a .node file: ${output.path}');
  }
  if (target.node != null) {
    throw UnsupportedError(
      'Node.js compatibility analysis is not implemented yet.',
    );
  }
  final outputType = FileSystemEntity.typeSync(output.path, followLinks: false);
  if (outputType != FileSystemEntityType.notFound &&
      outputType != FileSystemEntityType.file) {
    throw ArgumentError('Output must be a regular file: ${output.path}');
  }
  if (output.existsSync() &&
      source.resolveSymbolicLinksSync() == output.resolveSymbolicLinksSync()) {
    throw ArgumentError('Entry and output must be different files.');
  }
  final sdk = DartSdk.current();
  final template = await NativeTemplate.current(sdk);
  final workspace = await Directory.systemTemp.createTemp('napi-compile-');
  try {
    final entry = writeBindings(source, workspace);
    final snapshotFile = File('${workspace.path}/payload.aot');
    await sdk.compileAot(
      entry: entry,
      output: snapshotFile,
      packageConfig: _packageConfig(source),
    );

    // Build completely before touching the requested output. Staging next to it
    // keeps the final rename on the same filesystem.
    await output.parent.create(recursive: true);
    final staging = await output.parent.createTemp('.napi-');
    try {
      final candidate = File('${staging.path}/addon.node');
      await template.assemble(snapshotFile, candidate);
      await candidate.rename(output.path);
    } finally {
      await staging.delete(recursive: true);
    }
  } finally {
    await workspace.delete(recursive: true);
  }
}

File? _packageConfig(File entry) {
  var directory = entry.parent;
  while (true) {
    final config = File('${directory.path}/.dart_tool/package_config.json');
    if (config.existsSync()) return config;
    final parent = directory.parent;
    if (parent.path == directory.path) return null;
    directory = parent;
  }
}
