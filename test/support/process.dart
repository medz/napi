import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Run a directly owned subprocess and reap it before returning or throwing.
///
/// This does not terminate descendants. Use only for commands that do not spawn
/// subprocesses; compiler, npm and nested consumer runners need tree ownership.
/// A descendant holding an inherited output pipe is reported, not reaped.
Future<ProcessResult> runProcess(
  String executable,
  List<String> arguments, {
  required Duration timeout,
  String? workingDirectory,
}) async {
  final cwd = workingDirectory ?? Directory.current.path;
  final command =
      'Command: ${jsonEncode([executable, ...arguments])}\n'
      'Working directory: $cwd';
  final Process process;
  try {
    process = await Process.start(executable, arguments, workingDirectory: cwd);
  } on ProcessException catch (error) {
    throw ProcessException(
      executable,
      arguments,
      '$command\n${error.message}',
      error.errorCode,
    );
  }
  final output = BytesBuilder(copy: false);
  final errors = BytesBuilder(copy: false);
  final outputDone = Completer<void>();
  final errorsDone = Completer<void>();
  Object? outputError;
  void collect(BytesBuilder target, List<int> bytes) {
    const limit = 4 * 1024 * 1024;
    final remaining = limit - target.length;
    if (bytes.length > remaining) {
      outputError ??= StateError(
        'Output exceeded 4 MiB per stream; remaining bytes discarded.',
      );
      if (remaining > 0) target.add(bytes.sublist(0, remaining));
    } else {
      target.add(bytes);
    }
  }

  final outputSubscription = process.stdout.listen(
    (bytes) => collect(output, bytes),
    onError: (Object error) {
      outputError ??= error;
    },
    onDone: outputDone.complete,
  );
  final errorsSubscription = process.stderr.listen(
    (bytes) => collect(errors, bytes),
    onError: (Object error) {
      outputError ??= error;
    },
    onDone: errorsDone.complete,
  );
  final inputDone = process.stdin.close().then<void>(
    (_) {},
    onError: (Object error) {
      outputError ??= error;
    },
  );
  var exited = false;
  final exit = process.exitCode.then((code) {
    exited = true;
    return code;
  });
  final done = Future.wait<Object?>([
    inputDone,
    exit,
    outputDone.future,
    errorsDone.future,
  ]);
  var timedOut = false;
  var pipesOpen = false;
  try {
    await done.timeout(timeout);
  } on TimeoutException {
    timedOut = true;
  } finally {
    if (!exited) {
      process.kill(ProcessSignal.sigterm);
      try {
        await exit.timeout(const Duration(seconds: 1));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        await exit;
      }
    }
    try {
      await done.timeout(const Duration(seconds: 1));
    } on TimeoutException {
      pipesOpen = true;
      await outputSubscription.cancel();
      await errorsSubscription.cancel();
    }
  }
  final stdout = utf8.decode(output.takeBytes(), allowMalformed: true);
  final stderr = utf8.decode(errors.takeBytes(), allowMalformed: true);
  final code = await exit;
  final context =
      '$command\nPID: ${process.pid}\n'
      'stdout:\n$stdout\nstderr:\n$stderr'
      '${outputError == null ? '' : '\nI/O error: $outputError'}';
  if (timedOut || pipesOpen) {
    throw TimeoutException(
      '$context\nDeadline exceeded; direct child has exited.'
      '${pipesOpen ? ' Output pipes remain open; descendants may still be running and are not owned by this helper.' : ''}',
      timeout,
    );
  }
  if (outputError != null || code != 0) {
    throw ProcessException(executable, arguments, context, code);
  }
  return ProcessResult(process.pid, code, stdout, stderr);
}
