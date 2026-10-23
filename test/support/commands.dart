import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

final _nodeExecutables = _readNodeExecutables();

/// Validate the selected Node runtimes before building packages.
Future<void> reportNodeVersions() async {
  await _nodeExecutables;
}

/// Node runtimes selected for independent generated-consumer tests.
List<String> nodeExecutables() {
  final configured = Platform.environment['NAPI_NODE_EXECUTABLES'];
  final executables = <String>[];
  if (configured == null) {
    executables.add('node');
  } else {
    Object? decoded;
    try {
      decoded = jsonDecode(configured);
    } on FormatException {
      throw const FormatException(
        'NAPI_NODE_EXECUTABLES must be a nonempty JSON array of absolute executable paths.',
      );
    }
    if (decoded is! List || decoded.isEmpty) {
      throw const FormatException(
        'NAPI_NODE_EXECUTABLES must be a nonempty JSON array.',
      );
    }
    for (final executable in decoded) {
      if (executable is! String ||
          !path.isAbsolute(executable) ||
          !File(executable).existsSync() ||
          executables.contains(executable)) {
        throw const FormatException(
          'NAPI_NODE_EXECUTABLES requires distinct, existing absolute executable paths.',
        );
      }
      executables.add(executable);
    }
  }
  return List.unmodifiable(executables);
}

Future<List<String>> _readNodeExecutables() async {
  final executables = nodeExecutables();
  for (final executable in executables) {
    final version = await Process.run(executable, ['--version']);
    if (version.exitCode != 0) {
      throw StateError('$executable --version failed: ${version.stderr}');
    }
    final text = version.stdout.toString().trim();
    if (!RegExp(r'^v\d+\.\d+\.\d+(?:[-+][\w.-]+)?$').hasMatch(text)) {
      throw StateError('$executable did not report a Node version: $text');
    }
    stdout.writeln('Node $text: $executable');
  }
  return executables;
}

Future<void> run(String command, List<String> args, {String? cwd}) async {
  final executables = command == 'node' ? await _nodeExecutables : [command];
  for (final executable in executables) {
    await _run(executable, args, cwd: cwd);
  }
}

Future<void> _run(String executable, List<String> args, {String? cwd}) async {
  final result = await Process.run(executable, args, workingDirectory: cwd);
  if (result.exitCode != 0) {
    throw StateError(
      '$executable ${args.join(' ')} exited ${result.exitCode}\n'
      'Working directory: ${cwd ?? Directory.current.path}\n'
      'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
    );
  }
}

Future<void> typecheck(List<String> args, {required String cwd}) async {
  final tsc =
      Platform.environment['NAPI_TSC'] ??
      '${Directory.current.path}/.dart_tool/js/node_modules/typescript/bin/tsc';
  if (!File(tsc).existsSync()) {
    throw StateError(
      'Install TypeScript 7.0.2 under .dart_tool/js, or set NAPI_TSC.',
    );
  }
  await _run(Platform.environment['NAPI_TEST_NODE'] ?? 'node', [
    File(tsc).absolute.path,
    ...args,
  ], cwd: cwd);
}

Future<void> typescript(Directory directory, String consumer) async {
  for (final mode in ['NodeNext', 'Bundler']) {
    await typecheck([
      '--ignoreConfig',
      '--strict',
      '--exactOptionalPropertyTypes',
      '--noEmit',
      '--target',
      'ES2022',
      '--module',
      mode == 'NodeNext' ? 'NodeNext' : 'ESNext',
      '--moduleResolution',
      mode,
      '--allowArbitraryExtensions',
      consumer,
    ], cwd: directory.path);
  }
}
