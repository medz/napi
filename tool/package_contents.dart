import 'dart:io';

import 'package:path/path.dart' as path;

/// Check npm's actual tarball inventory against an independently chosen set.
void verifyPackedFiles(Map<String, dynamic> packed, Set<String> expected) {
  _verifyFiles(
    (packed['files'] as List).map((entry) => (entry as Map)['path'] as String),
    expected,
    'npm tarball',
  );
}

/// Generated packages contain flat regular files, including exact notices.
Future<void> verifyInstalledPackage(
  Directory directory,
  Set<String> expected,
  Map<String, List<int>> notices,
) async {
  final entries = await directory.list(followLinks: false).toList();
  for (final entry in entries) {
    if (entry is! File) {
      throw StateError('Installed package contains a non-file: ${entry.path}');
    }
  }
  _verifyFiles(
    entries.map((entry) => path.basename(entry.path)),
    expected,
    'installed package',
  );
  for (final notice in notices.entries) {
    final actual = await File('${directory.path}/${notice.key}').readAsBytes();
    if (actual.length != notice.value.length ||
        actual.indexed.any((entry) => entry.$2 != notice.value[entry.$1])) {
      throw StateError(
        'Installed notice differs from its source: ${notice.key}',
      );
    }
  }
}

void _verifyFiles(
  Iterable<String> files,
  Set<String> expected,
  String context,
) {
  final names = files.toList();
  final unique = names.toSet();
  final missing = expected.difference(unique).toList()..sort();
  final extra = unique.difference(expected).toList()..sort();
  if (names.length != unique.length || missing.isNotEmpty || extra.isNotEmpty) {
    throw StateError(
      '$context inventory mismatch: missing=$missing, extra=$extra, '
      'duplicates=${names.length - unique.length}',
    );
  }
}
