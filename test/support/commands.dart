import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'process.dart';

final _nodeExecutables = _readNodeExecutables();
final _windowsNpm = _readWindowsNpm();

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
    final version = await _process(executable, [
      '--version',
    ], timeout: const Duration(seconds: 10));
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
  final result = executable == 'npm'
      ? await npm(args, cwd: cwd)
      : await _process(executable, args, cwd: cwd);
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

Future<ProcessResult> _process(
  String executable,
  List<String> arguments, {
  String? cwd,
  Duration timeout = const Duration(minutes: 3),
}) => Platform.environment['NAPI_TEST_PROCESS_OWNER'] == '1'
    // Nested commands must remain in the enclosing consumer's process group.
    ? Process.run(executable, arguments, workingDirectory: cwd)
    : runProcess(
        executable,
        arguments,
        timeout: timeout,
        workingDirectory: cwd,
      );
Future<ProcessResult> npm(List<String> arguments, {String? cwd}) async {
  if (!Platform.isWindows) {
    return _process('npm', arguments, cwd: cwd);
  }
  final command = await _windowsNpm;
  return _process(command.node, [
    command.cli,
    ...arguments,
  ], cwd: cwd);
}

Future<({String node, String cli})> _readWindowsNpm() async {
  final result = await _process(
    'node',
    ['-p', 'process.execPath'],
    timeout: const Duration(seconds: 10),
  );
  if (result.exitCode != 0) {
    throw StateError('Cannot locate Node for npm: ${result.stderr}');
  }
  final node = result.stdout.toString().trim();
  final cli = File(
    path.join(path.dirname(node), 'node_modules/npm/bin/npm-cli.js'),
  );
  if (!path.isAbsolute(node) || !cli.existsSync()) {
    throw StateError(
      'The selected Windows Node installation is missing npm: $node',
    );
  }
  // npm.cmd cannot be launched as an executable. Use Node's bundled CLI without
  // a shell so paths with spaces retain their argument boundaries.
  return (node: node, cli: cli.path);
}
