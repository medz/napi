import 'dart:convert';
import 'dart:io';

import 'package:napi/src/bridge.dart';
import 'package:napi/src/exports.dart';
import 'package:napi/src/runtime.dart';
import 'package:napi/src/typescript.dart';
import 'package:path/path.dart' as p;

const _usage =
    '''Usage: dart run napi:build <dart-file> --name <npm-name> [options]

  --out <directory>    Output directory (default: dist)
  --version <version>  Generated npm package version (default: 0.1.0)
  --help               Show this help
''';

Future<void> main(List<String> arguments) async {
  if (arguments.contains('--help') || arguments.contains('-h')) {
    stdout.write(_usage);
    return;
  }
  try {
    await _build(arguments);
  } catch (error) {
    stderr.writeln('napi: $error');
    exitCode = 1;
  }
}

Future<void> _build(List<String> arguments) async {
  String? source;
  String? name;
  var out = 'dist';
  var version = '0.1.0';
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument.startsWith('-')) {
      if (!['--name', '--out', '--version'].contains(argument) ||
          index + 1 == arguments.length ||
          arguments[index + 1].startsWith('--')) {
        throw FormatException(
          'Unknown or incomplete option: $argument\n$_usage',
        );
      }
      final value = arguments[++index];
      switch (argument) {
        case '--name':
          name = value;
        case '--out':
          out = value;
        case '--version':
          version = value;
      }
    } else if (source == null) {
      source = argument;
    } else {
      throw FormatException('Unexpected argument: $argument\n$_usage');
    }
  }
  if (source == null || name == null) {
    throw FormatException('A Dart file and --name are required.\n$_usage');
  }
  final packageName = RegExp(
    r'^(?:@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*$',
  );
  if (!packageName.hasMatch(name) ||
      name.length > 214 ||
      name == 'node_modules') {
    throw FormatException('Invalid npm package name: $name');
  }
  final semver = RegExp(
    r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)'
    r'(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?'
    r'(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
  );
  final versionMatch = semver.firstMatch(version);
  final prerelease = versionMatch?.group(4);
  final leadingZero =
      prerelease
          ?.split('.')
          .any(
            (part) =>
                part.length > 1 &&
                part.startsWith('0') &&
                RegExp(r'^\d+$').hasMatch(part),
          ) ??
      false;
  if (versionMatch == null || leadingZero) {
    throw FormatException('Invalid npm package version: $version');
  }
  final entry = File(p.normalize(p.absolute(source)));
  if (!entry.existsSync() || p.extension(entry.path) != '.dart') {
    throw FormatException('Dart source file not found: ${entry.path}');
  }
  final destination = Directory(p.normalize(p.absolute(out)));
  if (p.equals(destination.path, entry.parent.path) ||
      p.isWithin(destination.path, entry.path)) {
    throw const FormatException(
      'The output directory contains the input source.',
    );
  }
  _checkDestination(destination);
  final exports = await readExports(entry.path);
  final project = _findProject(entry.parent);
  final workParent = Directory(p.join(project.path, '.dart_tool', 'napi'));
  await workParent.create(recursive: true);
  final work = await workParent.createTemp('build-');
  try {
    final bridge = File(p.join(work.path, 'bridge.dart'));
    await bridge.writeAsString(generateBridge(exports, entry.uri.toString()));
    final wasm = p.join(work.path, 'module.wasm');
    final result = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'wasm',
      '-E--enable-experimental-wasm-interop',
      '--no-source-maps',
      bridge.path,
      '-o',
      wasm,
    ], workingDirectory: project.path);
    if (result.exitCode != 0) {
      throw StateError(
        'Dart Wasm compilation failed:\n${result.stdout}${result.stderr}',
      );
    }
    final names = exports.map((export) => export.name).join(', ');
    await File(p.join(work.path, 'runtime.js'))
        .writeAsString(generateRuntime(exports));
    await File(p.join(work.path, 'node.js')).writeAsString(
      '''import { readFile as _napiReadFile } from 'node:fs/promises';
import { instantiate as _napiInstantiate } from './runtime.js';

export const { $names } = (await _napiInstantiate(
  await _napiReadFile(new URL('./module.wasm', import.meta.url)),
)).exports;
''',
    );
    await File(p.join(work.path, 'browser.js')).writeAsString(
      '''import { instantiate as _napiInstantiate } from './runtime.js';

const _napiResponse = await fetch(new URL('./module.wasm', import.meta.url));
if (!_napiResponse.ok) throw new Error(`Failed to load Wasm: \${_napiResponse.status}`);
export const { $names } = (await _napiInstantiate(await _napiResponse.arrayBuffer())).exports;
''',
    );
    await File(p.join(work.path, 'index.d.ts'))
        .writeAsString(generateTypescript(exports));
    final assets = [
      'node.js',
      'browser.js',
      'runtime.js',
      'index.d.ts',
      'module.wasm',
      'module.mjs',
      if (File(p.join(work.path, 'module.support.js')).existsSync())
        'module.support.js',
    ];
    final manifest = <String, Object>{
      'name': name,
      'version': version,
      'type': 'module',
      'types': './index.d.ts',
      'exports': {
        '.': {
          'types': './index.d.ts',
          'browser': './browser.js',
          'node': './node.js',
          'default': './browser.js',
        },
      },
      'files': assets,
      'engines': {'node': '>=22'},
      'napi': {'generator': 'napi', 'version': '0.1.0'},
    };
    await File(p.join(work.path, 'package.json')).writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
    );
    // Recheck after compilation; a failed build never modifies the output.
    _checkDestination(destination);
    await destination.create(recursive: true);
    for (final asset in [...assets, 'package.json']) {
      await File(p.join(work.path, asset))
          .copy(p.join(destination.path, asset));
    }
    stdout.writeln('Built $name@$version → ${destination.path}');
  } finally {
    await work.delete(recursive: true);
  }
}

Directory _findProject(Directory directory) {
  var current = directory;
  while (!File(p.join(current.path, 'pubspec.yaml')).existsSync()) {
    final parent = current.parent;
    if (parent.path == current.path) {
      throw const FormatException('Source must belong to a Dart package.');
    }
    current = parent;
  }
  if (!File(p.join(current.path, '.dart_tool', 'package_config.json'))
      .existsSync()) {
    throw const FormatException(
      'Run dart pub get in the source package first.',
    );
  }
  return current;
}

void _checkDestination(Directory directory) {
  if (FileSystemEntity.typeSync(directory.path, followLinks: false) ==
      FileSystemEntityType.link) {
    throw const FormatException(
      'Output directory must not be a symbolic link.',
    );
  }
  if (!directory.existsSync()) return;
  final entries = directory.listSync(followLinks: false);
  if (entries.isEmpty) return;
  final manifest = File(p.join(directory.path, 'package.json'));
  try {
    final data =
        jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>;
    if ((data['napi'] as Map<String, dynamic>?)?['generator'] != 'napi') {
      throw const FormatException();
    }
    final files = (data['files'] as List).cast<String>();
    for (final entry in entries) {
      final filename = p.basename(entry.path);
      if (entry is! File ||
          (filename != 'package.json' && !files.contains(filename))) {
        throw const FormatException();
      }
    }
  } catch (_) {
    throw FormatException(
      'Output is not an empty or generated napi directory: ${directory.path}',
    );
  }
}
