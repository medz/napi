import 'dart:convert';
import 'dart:io';

import 'package:pub_semver/pub_semver.dart';

import '../native/sdk.dart';
import '../target.dart';
import 'artifact.dart';
import 'loader.dart';
import 'output.dart';

const _singleFiles = [
  'addon.node',
  'index.cjs',
  'index.mjs',
  'index.d.cts',
  'index.d.mts',
  'package.json',
  'NOTICES',
  '.napi.json',
];
final _moduleNodes = VersionConstraint.parse('>=12.22.0');

Future<void> buildPackage(PackageBuild target) async {
  _checkName(target.name);
  if (Version.parse(target.version).toString() != target.version) {
    throw FormatException('Invalid npm package version: ${target.version}.');
  }
  if (target.node case final range?) {
    final requested = VersionConstraint.unionOf(
      range.split('||').map((part) => VersionConstraint.parse(part.trim())),
    );
    if (requested.isEmpty || !_moduleNodes.allowsAll(requested)) {
      throw const FormatException(
        'PackageBuild requires Node.js >=12.22.0 for its CJS/ESM entries.',
      );
    }
  }
  final entry = target.entry;
  final artifacts = <Artifact>[];
  if (entry == null) {
    if (target.artifacts.isEmpty) {
      throw ArgumentError(
        'PackageBuild requires at least one native artifact.',
      );
    }
    for (final input in target.artifacts) {
      artifacts.add(await Artifact.read(input));
    }
    _checkArtifacts(artifacts);
    if (artifacts.length > 1) {
      for (final artifact in artifacts) {
        _checkName('${target.name}-${artifact.platform.npmSuffix}');
      }
    }
  }
  final staged = await prepareOutput(
    target.output,
    entry: entry,
    inputs: [
      for (final input in target.artifacts) input.manifest,
      for (final artifact in artifacts) ...[
        artifact.binary,
        artifact.declarations,
        artifact.notices,
      ],
    ],
  );
  try {
    if (entry != null) {
      final workspace = await Directory.fromUri(
        staged.uri.resolve('.build/'),
      ).create();
      final sdk = await NativeSdk.current();
      final binary = File.fromUri(workspace.uri.resolve('addon.node'));
      final declarations = File.fromUri(workspace.uri.resolve('bindings.d.ts'));
      final report = sdk.compile(
        NativeTarget(
          entry: entry,
          output: binary,
          declarations: declarations,
          node: target.node,
        ),
        metadata: true,
      )!;
      final notices = await File.fromUri(
        sdk.assets.uri.resolve('NOTICES'),
      ).copy(File.fromUri(workspace.uri.resolve('NOTICES')).path);
      artifacts.add(
        await Artifact.create(
          report,
          binary: binary,
          declarations: declarations,
          notices: notices,
        ),
      );
      await _single(staged, target, artifacts.single);
      await workspace.delete(recursive: true);
    } else if (artifacts.length == 1) {
      await _single(staged, target, artifacts.single);
    } else {
      await _multiple(staged, target, artifacts);
    }
    await installOutput(staged, target.output);
  } finally {
    await discardOutput(staged);
  }
}

Future<void> _single(
  Directory staged,
  PackageBuild target,
  Artifact input,
) async {
  final artifact = await input.copyTo(staged);
  await _entries(staged, target.name, artifact.exports);
  await _json(staged, 'package.json', {
    ..._package(target, artifact.nodeConstraint.intersect(_moduleNodes)),
    ..._platform(artifact.platform),
    'files': _singleFiles.where((file) => file != '.napi.json').toList(),
  });
  await _json(
    staged,
    '.napi.json',
    await artifact.manifest(staged, files: _singleFiles),
  );
}

Future<void> _multiple(
  Directory staged,
  PackageBuild target,
  List<Artifact> artifacts,
) async {
  final packages = <NativePlatform, String>{};
  final files = <String>[
    'index.cjs',
    'index.mjs',
    'index.d.cts',
    'index.d.mts',
    'package.json',
    'NOTICES',
    '.napi.json',
  ];
  var nodes = _moduleNodes;
  Artifact? firstCopied;
  for (final input in artifacts) {
    nodes = nodes.intersect(input.nodeConstraint);
    final platform = input.platform;
    final name = '${target.name}-${platform.npmSuffix}';
    packages[platform] = name;
    final relative = 'platforms/${platform.id}';
    final directory = await Directory.fromUri(
      staged.uri.resolve('$relative/'),
    ).create(recursive: true);
    final artifact = await input.copyTo(directory);
    firstCopied ??= artifact;
    const leafFiles = [
      'addon.node',
      'index.d.cts',
      'NOTICES',
      'package.json',
      '.napi.json',
    ];
    await _json(directory, 'package.json', {
      'name': name,
      'version': target.version,
      'main': './addon.node',
      'types': './index.d.cts',
      'exports': {
        '.': {'types': './index.d.cts', 'require': './addon.node'},
      },
      'engines': {'node': artifact.node},
      ..._platform(platform),
      'files': leafFiles.where((file) => file != '.napi.json').toList(),
    });
    await _json(
      directory,
      '.napi.json',
      await artifact.manifest(directory, files: leafFiles),
    );
    files.addAll(leafFiles.map((file) => '$relative/$file'));
  }
  if (nodes.isEmpty) {
    throw const FormatException(
      'Native artifacts have no common Node.js version.',
    );
  }
  final first = firstCopied!;
  await first.declarations.copy(
    File.fromUri(staged.uri.resolve('index.d.cts')).path,
  );
  await first.notices.copy(File.fromUri(staged.uri.resolve('NOTICES')).path);
  await _entries(staged, target.name, first.exports, packages: packages);
  await _json(staged, 'package.json', {
    ..._package(target, nodes),
    'files': files
        .where((file) => !file.startsWith('platforms/') && file != '.napi.json')
        .toList(),
    'optionalDependencies': {
      for (final name in packages.values) name: target.version,
    },
  });
  await _json(staged, '.napi.json', {
    'format': 1,
    'kind': 'package',
    'files': files,
  });
}

Future<void> _entries(
  Directory directory,
  String name,
  List<({String name, String kind})> exports, {
  Map<NativePlatform, String>? packages,
}) async {
  await File.fromUri(
    directory.uri.resolve('index.cjs'),
  ).writeAsString(commonJsLoader(name, packages));
  await File.fromUri(
    directory.uri.resolve('index.mjs'),
  ).writeAsString(esmLoader(exports));
  await File.fromUri(
    directory.uri.resolve('index.d.mts'),
  ).writeAsString(esmDeclarations(exports));
}

Map<String, Object?> _package(PackageBuild target, VersionConstraint nodes) => {
  'name': target.name,
  'version': target.version,
  'type': 'commonjs',
  'main': './index.cjs',
  'module': './index.mjs',
  'types': './index.d.cts',
  'exports': {
    '.': {
      'import': {'types': './index.d.mts', 'default': './index.mjs'},
      'require': {'types': './index.d.cts', 'default': './index.cjs'},
    },
  },
  'engines': {'node': canonicalConstraint(nodes)},
};

Map<String, Object?> _platform(NativePlatform platform) => {
  'os': [platform.os],
  'cpu': [platform.cpu],
  if (platform.libc != null) 'libc': [platform.libc],
};

void _checkArtifacts(List<Artifact> artifacts) {
  final platforms = <NativePlatform>{};
  final first = artifacts.first;
  for (final artifact in artifacts) {
    if (!platforms.add(artifact.platform)) {
      throw FormatException(
        'Duplicate native platform: ${artifact.platform.id}.',
      );
    }
    if (artifact.hashes.declarations != first.hashes.declarations ||
        jsonEncode(
              artifact.exports
                  .map((entry) => [entry.name, entry.kind])
                  .toList(),
            ) !=
            jsonEncode(
              first.exports.map((entry) => [entry.name, entry.kind]).toList(),
            )) {
      throw const FormatException(
        'Native artifacts expose different declarations.',
      );
    }
  }
}

Future<void> _json(
  Directory directory,
  String name,
  Map<String, Object?> value,
) => File.fromUri(
  directory.uri.resolve(name),
).writeAsString('${const JsonEncoder.withIndent('  ').convert(value)}\n');

void _checkName(String name) {
  final scoped = name.startsWith('@');
  final parts = scoped ? name.substring(1).split('/') : [name];
  final package = parts.last;
  final valid =
      (!scoped || parts.length == 2) &&
      parts.every(
        (part) => part.isNotEmpty && Uri.encodeComponent(part) == part,
      ) &&
      !package.startsWith('.') &&
      !RegExp(r"[~'!()*]").hasMatch(package) &&
      (scoped || !RegExp(r'^[._-]').hasMatch(package));
  if (!valid ||
      name.length > 214 ||
      name.toLowerCase() != name ||
      _reservedPackages.contains(name)) {
    throw FormatException('Invalid or reserved npm package name: $name.');
  }
}

const _reservedPackages = {
  'node_modules',
  'favicon.ico',
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
