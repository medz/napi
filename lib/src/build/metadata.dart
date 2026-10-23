import 'dart:convert';

import '../compiler/native/platform.dart';

const generatedPackageFields = {
  'type',
  'files',
  'exports',
  'imports',
  'main',
  'module',
  'types',
  'typings',
  'browser',
  'bin',
};

// Legal unscoped npm names resolved as bare built-ins by supported Node versions.
// Keep build-time validation independent of Node installation. The conformance
// test compares this behavior with node:module on the tested Node matrix.
// Prefix-only modules (node:test, node:sqlite, node:sea, node:ffi) do not collide.
const _bareBuiltins = {
  'assert',
  'async_hooks',
  'buffer',
  'child_process',
  'cluster',
  'console',
  'constants',
  'crypto',
  'dgram',
  'diagnostics_channel',
  'dns',
  'domain',
  'events',
  'fs',
  'http',
  'http2',
  'https',
  'inspector',
  'module',
  'net',
  'os',
  'path',
  'perf_hooks',
  'process',
  'punycode',
  'querystring',
  'readline',
  'repl',
  'stream',
  'string_decoder',
  'sys',
  'timers',
  'tls',
  'trace_events',
  'tty',
  'url',
  'util',
  'v8',
  'vm',
  'wasi',
  'worker_threads',
  'zlib',
};

Map<String, Object?> packageMetadata(
  Map<String, Object?> metadata, {
  bool native = false,
  NativePlatform? nativePlatform,
}) {
  // Detach caller-owned nested data before analysis or compilation can yield.
  final package = (jsonDecode(jsonEncode(metadata)) as Map)
      .cast<String, Object?>();
  for (final field in generatedPackageFields) {
    if (package.containsKey(field)) {
      throw ArgumentError(
        'Package metadata "$field" conflicts with generated $field.',
      );
    }
  }
  final name = package['name'];
  // npm validates the whole unscoped name's initial character, while a scoped
  // leaf only forbids an initial period. Scopes retain encodeURIComponent's
  // unescaped ASCII characters; its special-character warning applies to the
  // leaf, not the scope.
  final unscoped = r'[a-z0-9][a-z0-9._-]*';
  final scope = r"[a-z0-9._~!()*'-]+";
  final leaf = r'[a-z0-9_-][a-z0-9._-]*';
  if (name is! String ||
      name.length > 214 ||
      !RegExp('^(?:$unscoped|@$scope/$leaf)\$').hasMatch(name) ||
      {'node_modules', 'favicon.ico'}.contains(name)) {
    throw ArgumentError('Invalid npm package name: $name');
  }
  if (_bareBuiltins.contains(name)) {
    throw ArgumentError(
      'Package name "$name" shadows a Node built-in. '
      'Use a scoped name such as @scope/$name.',
    );
  }
  final version = package['version'];
  if (version is! String ||
      version.length > 256 ||
      !RegExp(
        r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
        r'(?:-(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
        r'(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?'
        r'(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
      ).hasMatch(version) ||
      version.split(RegExp(r'[-+]')).first.split('.').any((part) {
        final value = int.tryParse(part);
        return value == null || value > 9007199254740991;
      })) {
    throw ArgumentError('Invalid npm package version: $version');
  }
  if (native || nativePlatform != null) {
    var candidates = nativePlatform == null
        ? NativePlatform.values
        : [nativePlatform];
    for (final field in ['os', 'cpu', 'libc']) {
      List<String>? value(NativePlatform profile) => switch (field) {
        'os' => [profile.nodePlatform],
        'cpu' => [profile.architecture],
        _ => profile.libc == null ? null : [profile.libc!],
      };
      if (package.containsKey(field)) {
        candidates = candidates
            .where(
              (profile) =>
                  jsonEncode(package[field]) == jsonEncode(value(profile)),
            )
            .toList();
        if (candidates.isEmpty) {
          throw ArgumentError(
            'Native package metadata $field must match ${nativePlatform == null ? 'a supported native target' : value(nativePlatform)}.',
          );
        }
      }
      // An unresolved build may validate platform restrictions, but only the
      // actual bundle can supply the generated package's target fields.
      if (nativePlatform != null && value(nativePlatform) != null) {
        package[field] = value(nativePlatform);
      }
    }
  }
  return package;
}
