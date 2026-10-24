import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:crypto/crypto.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as path;

/// Watch the input graph, including unresolved files and conditional branches.
///
/// Parsing directives instead of resolving elements keeps error recovery
/// independent of successful compilation. SDK files are not editable inputs.
Future<Map<String, String?>> readBuildInputs(
  Uri library, {
  String? packagesPath,
  Iterable<File> assets = const [],
}) async {
  final inputs = <String, String?>{};
  final pending = <Uri>[library];
  final seen = <Uri>{};
  File? config;
  if (packagesPath != null) {
    config = File(packagesPath).absolute;
  } else {
    var directory = library.scheme == 'file'
        ? File.fromUri(library).absolute.parent
        : Directory.current.absolute;
    while (true) {
      final candidate = File(
        '${directory.path}/.dart_tool/package_config.json',
      );
      if (await candidate.exists()) {
        config = candidate;
        break;
      }
      if (directory.parent.path == directory.path) break;
      directory = directory.parent;
    }
    config ??= File('.dart_tool/package_config.json').absolute;
  }
  var packages = PackageConfig.empty;
  try {
    final bytes = await config.readAsBytes();
    inputs[path.normalize(config.path)] = sha256.convert(bytes).toString();
    packages = PackageConfig.parseBytes(bytes, config.uri, onError: (_) {});
  } on FileSystemException {
    inputs[path.normalize(config.path)] = null;
  } on FormatException {
    // The normal build reports invalid configuration. Retain the config watch.
  }
  for (final asset in assets) {
    final file = asset.absolute;
    inputs[path.normalize(file.path)] = await _digest(file);
  }
  while (pending.isNotEmpty) {
    var uri = pending.removeLast();
    final File file;
    try {
      if (uri.scheme == 'package') {
        final resolved = packages.resolve(uri);
        if (resolved == null) continue;
        uri = resolved;
      }
      if (uri.scheme != 'file' || !seen.add(uri)) continue;
      file = File.fromUri(uri).absolute;
    } on ArgumentError {
      // Incomplete imports are normal while editing. The compiler reports
      // them; watching the containing file lets the next save recover.
      continue;
    } on UnsupportedError {
      continue;
    }
    final name = path.normalize(file.path);
    String contents;
    try {
      final bytes = await file.readAsBytes();
      inputs[name] = sha256.convert(bytes).toString();
      contents = utf8.decode(bytes);
    } on FileSystemException {
      inputs[name] = null;
      continue;
    } on FormatException {
      continue;
    }
    final unit = parseString(content: contents, throwIfDiagnostics: false).unit;
    for (final directive in unit.directives.whereType<UriBasedDirective>()) {
      for (final literal in [
        directive.uri,
        if (directive is NamespaceDirective)
          ...directive.configurations.map((condition) => condition.uri),
      ]) {
        final value = literal.stringValue;
        if (value == null) continue;
        final dependency = Uri.tryParse(value);
        if (dependency != null) pending.add(uri.resolveUri(dependency));
      }
    }
  }
  final canonical = <String, String?>{...inputs};
  final ancestors = <String>{};
  for (final entry in inputs.entries) {
    final file = File(entry.key);
    // A directory link can be replaced without touching its old target.
    // Watch the link itself so retargeting it rediscovers the input graph.
    var ancestor = file.path;
    while (ancestors.add(ancestor)) {
      try {
        if (await FileSystemEntity.type(ancestor, followLinks: false) ==
            FileSystemEntityType.link) {
          canonical[ancestor] = 'link:${await Link(ancestor).target()}';
        }
      } on FileSystemException {
        canonical[ancestor] = null;
      }
      final parent = path.dirname(ancestor);
      if (parent == ancestor) break;
      ancestor = parent;
    }
    // macOS may report /private/var events for a /var input, and package roots
    // can point through symlinks. Keep both names for replacement and writes.
    var parent = file.parent;
    while (!await parent.exists() && parent.parent.path != parent.path) {
      parent = parent.parent;
    }
    var parentPath = parent.path;
    try {
      parentPath = await parent.resolveSymbolicLinks();
    } on FileSystemException {
      // An editor may remove an input directory while the graph is read.
    }
    final name = path.join(
      parentPath,
      path.relative(file.path, from: parent.path),
    );
    canonical[name] = entry.value;
    try {
      canonical[await file.resolveSymbolicLinks()] = entry.value;
    } on FileSystemException {
      // Missing inputs remain watched through their nearest existing parent.
    }
  }
  return canonical;
}

Future<String?> _digest(File file) async {
  try {
    return sha256.convert(await file.readAsBytes()).toString();
  } on FileSystemException {
    return null;
  }
}

/// Serialize builds and coalesce saves while a build is running.
Future<void> watchBuild({
  required Uri library,
  required Directory output,
  required Future<void> Function() build,
  required Stream<void> stop,
  String? packagesPath,
  Iterable<File> assets = const [],
}) async {
  final subscriptions = <String, StreamSubscription<FileSystemEvent>>{};
  var inputs = <String, String?>{};
  Map<String, String?>? attempted;
  var wake = Completer<void>();
  var stopped = false;
  var revision = 0;
  Object? watchError;
  Timer? debounce;
  void notify() {
    revision++;
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 150), () {
      if (!wake.isCompleted) wake.complete();
    });
  }

  final stopSubscription = stop.listen((_) {
    stopped = true;
    if (!wake.isCompleted) wake.complete();
  });
  Future<void> updateWatches() async {
    final directories = <String>{};
    for (final name in inputs.keys) {
      var directory = Directory(path.dirname(name));
      while (!await directory.exists()) {
        final parent = directory.parent;
        if (parent.path == directory.path) break;
        directory = parent;
      }
      directories.add(path.normalize(directory.path));
    }
    for (final name in subscriptions.keys.toList()) {
      if (!directories.contains(name)) {
        await subscriptions.remove(name)?.cancel();
      }
    }
    for (final name in directories.difference(subscriptions.keys.toSet())) {
      subscriptions[name] = Directory(name).watch().listen(
        (event) {
          final changed = [
            path.normalize(event.path),
            if (event is FileSystemMoveEvent && event.destination != null)
              path.normalize(event.destination!),
          ];
          if (changed.any(
            (name) => inputs.keys.any(
              (input) => path.equals(input, name) || path.isWithin(name, input),
            ),
          )) {
            notify();
          }
        },
        onError: (Object error) {
          if (!Directory(name).existsSync()) {
            notify();
            return;
          }
          watchError = error;
          stopped = true;
          if (!wake.isCompleted) wake.complete();
        },
        onDone: () {
          subscriptions.remove(name);
          if (!stopped) notify();
        },
      );
    }
  }

  try {
    stdout.writeln('Watching Dart sources. Press Ctrl+C to stop.');
    while (!stopped) {
      final before = revision;
      wake = Completer<void>();
      inputs = await readBuildInputs(
        library,
        packagesPath: packagesPath,
        assets: assets,
      );
      final destination = path.normalize(output.absolute.path);
      if (inputs.keys.any(
        (input) =>
            path.equals(input, destination) ||
            path.isWithin(destination, input),
      )) {
        throw ArgumentError(
          'Watched inputs must be outside the output directory.',
        );
      }
      await updateWatches();
      if (stopped) break;
      if (attempted == null || !_sameInputs(attempted, inputs)) {
        attempted = inputs;
        await build();
      }
      if (stopped) break;
      final after = await readBuildInputs(
        library,
        packagesPath: packagesPath,
        assets: assets,
      );
      if (!_sameInputs(inputs, after)) notify();
      if (revision == before) await wake.future;
      if (!stopped && debounce?.isActive == true) await wake.future;
    }
    if (watchError != null) throw watchError!;
  } finally {
    stopped = true;
    debounce?.cancel();
    await stopSubscription.cancel();
    for (final subscription in subscriptions.values.toList()) {
      await subscription.cancel();
    }
  }
}

bool _sameInputs(Map<String, String?> left, Map<String, String?> right) =>
    left.length == right.length &&
    left.entries.every(
      (entry) =>
          right.containsKey(entry.key) && right[entry.key] == entry.value,
    );
