import 'dart:convert';
import 'dart:io';

/// Creates a staging directory beside an output that can safely be replaced.
Future<Directory> prepareOutput(
  Directory output, {
  File? entry,
  Iterable<File> inputs = const [],
}) async {
  final destination = await _destination(output);
  for (final input in [?entry, ...inputs]) {
    final path = await input.resolveSymbolicLinks();
    if (_inside(destination.path, path)) {
      throw StateError('Output would replace an input file: ${input.path}');
    }
  }
  await _checkInventory(destination);
  return destination.parent.createTemp('.napi-stage-');
}

/// Installs a completed stage, retaining the previous directory on failure.
Future<void> installOutput(Directory staged, Directory output) async {
  final destination = await _destination(output);
  final stage = await _destination(staged);
  if (_inside(destination.path, stage.path) ||
      _inside(stage.path, destination.path) ||
      stage.parent.path != destination.parent.path) {
    throw StateError('Staging and output must be separate sibling directories');
  }
  await _checkInventory(stage, completed: true);
  // A build may take time; check for user files added since prepareOutput.
  await _checkInventory(destination);
  Directory? backupRoot;
  Directory? backup;
  if (await destination.exists()) {
    backupRoot = await destination.parent.createTemp('.napi-backup-');
    backup = Directory('${backupRoot.path}${Platform.pathSeparator}previous');
    try {
      await destination.rename(backup.path);
    } catch (_) {
      await backupRoot.delete();
      rethrow;
    }
  }
  try {
    if (await FileSystemEntity.type(destination.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw StateError('Output appeared while installing: ${destination.path}');
    }
    await stage.rename(destination.path);
  } catch (error) {
    if (backup != null) {
      try {
        if (await FileSystemEntity.type(destination.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw StateError('Output path is occupied');
        }
        await backup.rename(destination.path);
      } catch (recovery) {
        throw StateError(
          'Cannot install output: $error. '
          'Previous output retained at ${backup.path}: $recovery',
        );
      }
      await backupRoot!.delete();
    }
    rethrow;
  }
  if (backup != null) {
    try {
      await _checkInventory(backup);
      await backup.delete(recursive: true);
      await backupRoot!.delete();
    } catch (error) {
      throw StateError(
        'Output installed, but previous output remains at ${backup.path}: $error',
      );
    }
  }
}

/// Removes a temporary directory returned by [prepareOutput].
Future<void> discardOutput(Directory staged) async {
  final type = await FileSystemEntity.type(staged.path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return;
  if (type != FileSystemEntityType.directory) {
    throw StateError('Staging path is not a directory: ${staged.path}');
  }
  await for (final entity in staged.list(recursive: true, followLinks: false)) {
    if (entity is Link) {
      throw StateError('Unexpected symbolic link in staging: ${entity.path}');
    }
  }
  await staged.delete(recursive: true);
}

Future<Directory> _destination(Directory output) async {
  var path = output.absolute.path;
  // A trailing separator can make lstat follow a directory symlink.
  while ((path.endsWith('/') || Platform.isWindows && path.endsWith('\\')) &&
      Directory(path).parent.path != path) {
    path = path.substring(0, path.length - 1);
  }
  final directory = Directory(path);
  final type = await FileSystemEntity.type(path, followLinks: false);
  if (type == FileSystemEntityType.directory) {
    return Directory(await directory.resolveSymbolicLinks());
  }
  if (type != FileSystemEntityType.notFound) {
    throw StateError('Output must be a directory, not a file or link: $path');
  }
  await directory.parent.create(recursive: true);
  final parent = Directory(await directory.parent.resolveSymbolicLinks());
  final components = Platform.isWindows ? path.replaceAll('\\', '/') : path;
  final name = components.split('/').last;
  return Directory.fromUri(parent.uri.resolveUri(Uri(path: '$name/')));
}

bool _inside(String directory, String path) {
  if (Platform.isWindows) {
    directory = directory.toLowerCase();
    path = path.toLowerCase();
  }
  final prefix = directory.endsWith(Platform.pathSeparator)
      ? directory
      : '$directory${Platform.pathSeparator}';
  return path == directory || path.startsWith(prefix);
}

Future<void> _checkInventory(
  Directory directory, {
  bool completed = false,
}) async {
  final type = await FileSystemEntity.type(directory.path, followLinks: false);
  if (type == FileSystemEntityType.notFound && !completed) return;
  if (type != FileSystemEntityType.directory) {
    throw StateError('Output must be a directory: ${directory.path}');
  }
  final entries = await directory
      .list(recursive: true, followLinks: false)
      .toList();
  if (entries.isEmpty && !completed) return;
  final marker = File('${directory.path}${Platform.pathSeparator}.napi.json');
  if (await FileSystemEntity.type(marker.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw StateError('Output is not generated by napi: ${directory.path}');
  }
  final Object? manifest;
  try {
    manifest = jsonDecode(await marker.readAsString());
  } on FormatException {
    throw StateError('Invalid generated-file inventory: ${marker.path}');
  }
  if (manifest is! Map ||
      manifest['format'] != 1 ||
      !['native', 'package'].contains(manifest['kind']) ||
      manifest['files'] is! List) {
    throw StateError('Invalid generated-file inventory: ${marker.path}');
  }
  final files = <String>{};
  final directories = <String>{};
  for (final file in manifest['files'] as List) {
    if (file is! String ||
        file.contains('\\') ||
        file.contains(':') ||
        file.split('/').any((p) => p.isEmpty || p == '.' || p == '..') ||
        !files.add(file)) {
      throw StateError('Invalid generated-file path in ${marker.path}');
    }
    final components = file.split('/');
    for (var i = 1; i < components.length; i++) {
      directories.add(components.take(i).join('/'));
    }
  }
  if (!files.contains('.napi.json')) {
    throw StateError('Inventory does not include .napi.json: ${marker.path}');
  }
  final prefix = '${directory.path}${Platform.pathSeparator}';
  for (final entity in entries) {
    var name = entity.path.substring(prefix.length);
    if (Platform.isWindows) name = name.replaceAll('\\', '/');
    if (entity is Link ||
        entity is Directory && !directories.contains(name) ||
        entity is! Directory && !files.contains(name)) {
      throw StateError(
        'Output contains an unowned file or link: ${entity.path}',
      );
    }
  }
}
