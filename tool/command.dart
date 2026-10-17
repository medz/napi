import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

final _nodeExecutables = _readNodeExecutables();

/// Select the Node runtimes before compiling a conformance fixture.
Future<void> reportNodeVersions() async {
  await _nodeExecutables;
}

Future<List<String>> _readNodeExecutables() async {
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

/// Reuse the same generated artifacts for every selected Node runtime.
/// Dart compilation and npm packing/installing still execute once.
Future<void> run(String command, List<String> args, {String? cwd}) async {
  final executables = command == 'node' ? await _nodeExecutables : [command];
  for (final executable in executables) {
    if (command == 'node') stdout.writeln('Running Node: $executable');
    final result = await Process.run(executable, args, workingDirectory: cwd);
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    if (result.exitCode != 0) {
      throw StateError(
        '$executable ${args.join(' ')} exited ${result.exitCode}',
      );
    }
  }
}
