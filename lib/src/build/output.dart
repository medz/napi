import 'dart:io';

import 'package:path/path.dart' as path;

import 'output_ownership.dart';
import 'publish.dart';

final class OutputUpdate {
  OutputUpdate(this.previous, this.lock);
  final OutputOwnership? previous;
  final PackageLock? lock;

  static Future<OutputUpdate> open(
    Directory output, {
    OutputKind kind = OutputKind.package,
  }) async {
    await checkOutputPath(output.path);
    final type = await FileSystemEntity.type(output.path, followLinks: false);
    if (type != FileSystemEntityType.notFound) {
      if (type != FileSystemEntityType.directory ||
          await FileSystemEntity.type(
                '${output.path}/$outputOwnershipFile',
                followLinks: false,
              ) !=
              FileSystemEntityType.file) {
        throw ArgumentError(
          'Build output already exists without managed ownership: ${output.path}',
        );
      }
      checkPackageRebuildFilesystem(output);
    }
    await output.parent.create(recursive: true);
    final lock = Platform.isWindows ? null : PackageLock.acquire(output);
    try {
      final previous = await OutputOwnership.read(output, kind: kind);
      if (previous != null) checkPackageRebuildFilesystem(output);
      return OutputUpdate(previous, lock);
    } catch (_) {
      lock?.release();
      rethrow;
    }
  }

  void close() => lock?.release();
}

Future<void> checkOutputInputs(
  Directory output,
  Iterable<FileSystemEntity> inputs,
) async {
  await checkOutputPath(output.absolute.path);
  for (final input in inputs) {
    final source = input.absolute.path;
    await checkOutputPath(source);
    if (path.equals(source, output.path) ||
        path.isWithin(source, output.path) ||
        path.isWithin(output.path, source) ||
        await _containsExistingPath(source, output.absolute.path) ||
        await _containsExistingPath(output.absolute.path, source)) {
      throw ArgumentError(
        'Build inputs and output must not contain one another: $source',
      );
    }
  }
}

Future<bool> _containsExistingPath(String parent, String child) async {
  if (await FileSystemEntity.type(parent, followLinks: false) ==
      FileSystemEntityType.notFound) {
    return false;
  }
  // realpath alone can preserve an alias's case/Unicode spelling. Identity of
  // existing ancestors also covers outputs whose final segments do not exist.
  var current = path.normalize(child);
  while (true) {
    if (await FileSystemEntity.type(current, followLinks: false) !=
            FileSystemEntityType.notFound &&
        await FileSystemEntity.identical(parent, current)) {
      return true;
    }
    final next = path.dirname(current);
    if (next == current) return false;
    current = next;
  }
}

Future<void> checkOutputPath(String value) async {
  if (value.contains('\x00') || path.split(value).contains('..')) {
    throw ArgumentError(
      'Build paths must not contain NUL or traversal: $value',
    );
  }
  var current = path.rootPrefix(value);
  for (final segment in path.split(value).skip(1)) {
    current = path.join(current, segment);
    if (await FileSystemEntity.type(current, followLinks: false) ==
        FileSystemEntityType.link) {
      throw ArgumentError('Build paths must not contain symlinks: $current');
    }
  }
}
