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
  final input = File(p.normalize(p.absolute(source)));
  if (!input.existsSync()) {
    throw FormatException('Dart source file not found: ${input.path}');
  }
  final entry = File(input.resolveSymbolicLinksSync());
  if (!entry.existsSync() || p.extension(entry.path) != '.dart') {
    throw FormatException('Dart source file not found: ${entry.path}');
  }
  final destination = _resolveDestination(out);
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
    final bindings = [
      for (var index = 0; index < exports.length; index++)
        '${exports[index].name}: _napi$index',
    ].join(', ');
    final reexports = [
      for (var index = 0; index < exports.length; index++)
        '_napi$index as ${exports[index].name}',
    ].join(', ');
    await File(p.join(work.path, 'runtime.js'))
        .writeAsString(generateRuntime(exports));
    await File(p.join(work.path, 'node.js')).writeAsString(
      '''import { readFile as _napiReadFile } from 'node:fs/promises';
import { instantiate as _napiInstantiate } from './runtime.js';

const { $bindings } = (await _napiInstantiate(
  await _napiReadFile(new URL('./module.wasm', import.meta.url)),
)).exports;
export { $reexports };
''',
    );
    await File(p.join(work.path, 'browser.js')).writeAsString(
      '''import { instantiate as _napiInstantiate } from './runtime.js';

const _napiResponse = await fetch(new URL('./module.wasm', import.meta.url));
if (!_napiResponse.ok) throw new Error(`Failed to load Wasm: \${_napiResponse.status}`);
const { $bindings } = (await _napiInstantiate(await _napiResponse.arrayBuffer())).exports;
export { $reexports };
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
    // Resolve again in case an output ancestor changed during compilation.
    if (_resolveDestination(out).path != destination.path) {
      throw const FormatException('Output path changed during compilation.');
    }
    await _publishOutput(work, destination, [...assets, 'package.json']);
    stdout.writeln('Built $name@$version → ${destination.path}');
  } finally {
    await work.delete(recursive: true);
  }
}

Directory _findProject(Directory directory) {
  var current = directory;
  var foundPackage = false;
  while (true) {
    foundPackage |= File(p.join(current.path, 'pubspec.yaml')).existsSync();
    if (foundPackage &&
        File(p.join(current.path, '.dart_tool', 'package_config.json'))
            .existsSync()) {
      return current;
    }
    final parent = current.parent;
    if (parent.path == current.path) break;
    current = parent;
  }
  throw FormatException(
    foundPackage
        ? 'Run dart pub get in the source package or workspace first.'
        : 'Source must belong to a Dart package.',
  );
}

Directory _resolveDestination(String output) {
  final absolute = p.normalize(p.absolute(output));
  if (FileSystemEntity.typeSync(absolute, followLinks: false) ==
      FileSystemEntityType.link) {
    throw const FormatException(
      'Output directory must not be a symbolic link.',
    );
  }
  var ancestor = Directory(absolute);
  while (!ancestor.existsSync()) {
    if (FileSystemEntity.typeSync(ancestor.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FormatException(
        'Output path contains a broken symbolic link.',
      );
    }
    final parent = ancestor.parent;
    if (parent.path == ancestor.path) {
      throw const FormatException(
        'Output path has no existing directory ancestor.',
      );
    }
    ancestor = parent;
  }
  final resolved = ancestor.resolveSymbolicLinksSync();
  final suffix = p.relative(absolute, from: ancestor.path);
  return Directory(p.normalize(p.join(resolved, suffix)));
}

Future<void> _publishOutput(
  Directory work,
  Directory destination,
  List<String> assets,
) async {
  await destination.parent.create(recursive: true);
  // Stage on the destination filesystem; copy failures leave the old package intact.
  final staged = await destination.parent.createTemp('.napi-stage-');
  final backup = Directory('${staged.path}-previous');
  try {
    for (final asset in assets) {
      await File(p.join(work.path, asset)).copy(p.join(staged.path, asset));
    }
    _checkDestination(destination);
    final hadPrevious = destination.existsSync();
    if (hadPrevious) await destination.rename(backup.path);
    try {
      await staged.rename(destination.path);
    } catch (_) {
      if (hadPrevious) await backup.rename(destination.path);
      rethrow;
    }
    if (hadPrevious) {
      try {
        await backup.delete(recursive: true);
      } on FileSystemException {
        stderr.writeln('napi: previous output retained at ${backup.path}');
      }
    }
  } finally {
    if (staged.existsSync()) await staged.delete(recursive: true);
  }
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
    const generated = {
      'node.js',
      'browser.js',
      'runtime.js',
      'index.d.ts',
      'module.wasm',
      'module.mjs',
      'module.support.js',
    };
    if (files.any((file) => !generated.contains(file))) {
      throw const FormatException();
    }
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
