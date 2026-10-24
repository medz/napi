import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'output_ownership.dart';
import 'publish.dart';

final class OutputUpdate {
  OutputUpdate(this.previous, this.lock);
  final OutputOwnership? previous;
  final PackageLock lock;

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
    final lock = PackageLock.acquire(output);
    try {
      if (lock.recoveryDirectory case final directory?) {
        await _recoverWindowsOutput(output, directory, kind);
      }
      final previous = await OutputOwnership.read(output, kind: kind);
      if (previous != null) checkPackageRebuildFilesystem(output);
      return OutputUpdate(previous, lock);
    } catch (_) {
      lock.release();
      rethrow;
    }
  }

  Future<void> replace(Directory staging, Directory output) async {
    final state = lock.recoveryDirectory;
    if (state == null) {
      exchangeDirectories(staging, output);
      return;
    }
    final old = previous!;
    final next = (await OutputOwnership.read(staging, kind: old.kind))!;
    final journal = File(path.join(state.path, 'replacement.json'));
    final temporary = File(path.join(state.path, 'replacement.tmp'));
    final backup = Directory(path.join(state.path, 'previous'));
    await _writeReplacement(temporary, journal, {
      'format': 1,
      'kind': old.kind.name,
      'previous': old.recoveryFingerprint,
      'entries': old.recoveryEntries,
      'next': next.recoveryFingerprint,
      'committed': false,
    });
    // The old result is never edited in place. Windows permits a short gap
    // between these two no-replace renames.
    try {
      await next.checkUnchanged();
      await old.checkUnchanged();
      publishDirectory(output, backup);
    } catch (_) {
      await journal.delete();
      rethrow;
    }
    try {
      publishDirectory(staging, output);
    } catch (error) {
      try {
        publishDirectory(backup, output);
        await journal.delete();
      } catch (restoreError) {
        throw FileSystemException(
          'Windows replacement failed: $error. The previous result is retained '
          'at ${backup.path}; recovery also failed: $restoreError',
          output.path,
        );
      }
      rethrow;
    }
    // The new directory is committed. Failures from this point are cleanup
    // diagnostics and must not turn a successful build into a rollback.
    try {
      await _writeReplacement(temporary, journal, {
        'format': 1,
        'kind': old.kind.name,
        'previous': old.recoveryFingerprint,
        'entries': old.recoveryEntries,
        'next': next.recoveryFingerprint,
        'committed': true,
      });
      await backup.delete(recursive: true);
      await journal.delete();
    } catch (error) {
      try {
        stderr.writeln(
          'Build committed; recovery files retained at ${state.path}: $error',
        );
      } catch (_) {
        /* The result remains committed. */
      }
    }
  }

  void close() => lock.release();
}

Future<void> _writeReplacement(
  File temporary,
  File journal,
  Map<String, Object> value,
) async {
  for (final file in [temporary, journal]) {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.notFound) {
      throw FileSystemException(
        'Windows replacement record is not a regular file.',
        file.path,
      );
    }
  }
  await temporary.writeAsString(jsonEncode(value), flush: true);
  await temporary.rename(journal.path);
}

Future<void> _recoverWindowsOutput(
  Directory output,
  Directory state,
  OutputKind kind,
) async {
  final journal = File(path.join(state.path, 'replacement.json'));
  final backup = Directory(path.join(state.path, 'previous'));
  final type = await FileSystemEntity.type(journal.path, followLinks: false);
  final backupType = await FileSystemEntity.type(
    backup.path,
    followLinks: false,
  );
  if (type == FileSystemEntityType.notFound) {
    if (backupType != FileSystemEntityType.notFound) {
      throw FileSystemException(
        'Unrecorded Windows build backup; retained without changes.',
        backup.path,
      );
    }
    return;
  }
  if (type != FileSystemEntityType.file) {
    throw FileSystemException(
      'Invalid Windows replacement record; retained without changes.',
      journal.path,
    );
  }
  final record = jsonDecode(await journal.readAsString());
  if (record is! Map<String, dynamic> ||
      record['format'] != 1 ||
      record['kind'] != kind.name ||
      record['committed'] is! bool ||
      record['entries'] is! Map<String, dynamic> ||
      (record['entries'] as Map<String, dynamic>).entries.any(
        (entry) =>
            (entry.key.isNotEmpty &&
                (path.isAbsolute(entry.key) ||
                    path.normalize(entry.key) != entry.key ||
                    path
                        .split(entry.key)
                        .any((part) => part == '..' || part == '.'))) ||
            (entry.value != null &&
                (entry.value is! String ||
                    !RegExp(r'^[a-f0-9]{64}$')
                        .hasMatch(entry.value as String))),
      ) ||
      !['previous', 'next'].every(
        (field) =>
            record[field] is String &&
            RegExp(r'^[a-f0-9]{64}$').hasMatch(record[field] as String),
      )) {
    throw FileSystemException(
      'Invalid Windows replacement record; retained without changes.',
      journal.path,
    );
  }
  final entries = record['entries'] as Map<String, dynamic>;
  if (OutputOwnership.recoveryIdentity(kind, entries) != record['previous']) {
    throw FileSystemException('Invalid Windows backup snapshot.', journal.path);
  }
  checkPackageRebuildFilesystem(state);
  if (backupType != FileSystemEntityType.directory &&
      backupType != FileSystemEntityType.notFound) {
    throw FileSystemException(
      'Windows build backup is not a regular directory.',
      backup.path,
    );
  }
  final current = await OutputOwnership.read(output, kind: kind);
  if (current?.recoveryFingerprint == record['next']) {
    // Publication succeeded, including interruption before its cleanup marker.
    if (backupType != FileSystemEntityType.notFound) {
      if (record['committed'] == true) {
        await OutputOwnership.checkRecoveryRemainder(backup, entries);
      } else {
        final previous = await OutputOwnership.read(backup, kind: kind);
        if (previous?.recoveryFingerprint != record['previous']) {
          throw FileSystemException(
            'Windows build backup changed; retained without changes.',
            backup.path,
          );
        }
      }
      await _writeReplacement(
        File(path.join(state.path, 'replacement.tmp')),
        journal,
        {...record.cast<String, Object>(), 'committed': true},
      );
      await backup.delete(recursive: true);
    }
    await journal.delete();
    return;
  }
  if (record['committed'] == true) {
    throw FileSystemException(
      'Committed Windows output changed; recovery files were retained.',
      output.path,
    );
  }
  if (current?.recoveryFingerprint == record['previous'] &&
      backupType == FileSystemEntityType.notFound) {
    await journal.delete(); // The first rename never happened, or was restored.
    return;
  }
  if (current == null) {
    final previous = await OutputOwnership.read(backup, kind: kind);
    if (previous?.recoveryFingerprint == record['previous']) {
      publishDirectory(backup, output);
      await journal.delete();
      return;
    }
  }
  throw FileSystemException(
    'Windows rebuild recovery conflicts with changed output; '
    'the output and backup were retained.',
    output.path,
  );
}

Future<void> checkOutputInputs(
  Directory output,
  Iterable<FileSystemEntity> inputs,
) async {
  await checkOutputPath(output.absolute.path);
  for (final input in inputs) {
    final source = input.absolute.path;
    await checkOutputPath(source);
    if (Platform.isWindows) checkOutputLockPath(Directory(source));
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
