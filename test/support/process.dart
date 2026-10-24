import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Run a test command in an owned Unix process group or Windows Job Object.
/// The command's exit code is preserved after its remaining descendants stop.
Future<ProcessResult> runProcess(
  String executable,
  List<String> arguments, {
  required Duration timeout,
  String? workingDirectory,
  Map<String, String>? environment,
  bool checkExitCode = true,
}) async {
  final clock = Stopwatch()..start();
  final cwd = workingDirectory ?? Directory.current.path;
  final command =
      'Command: ${jsonEncode([executable, ...arguments])}\n'
      'Working directory: $cwd';
  final control = await Directory.systemTemp.createTemp('napi process ');
  final stateFile = File('${control.path}/state.json');
  final Process process;
  try {
    process = await Process.start(
      Platform.environment['NAPI_TEST_PYTHON'] ??
          (Platform.isWindows ? 'python' : 'python3'),
      [
        File('test/support/process_owner.py').absolute.path,
        stateFile.path,
        executable,
        ...arguments,
      ],
      workingDirectory: cwd,
      environment: {'NAPI_TEST_PROCESS_OWNER': '1', ...?environment},
    );
  } on ProcessException catch (error) {
    await control.delete(recursive: true);
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
    onError: (Object error) => outputError ??= error,
    onDone: outputDone.complete,
  );
  final errorsSubscription = process.stderr.listen(
    (bytes) => collect(errors, bytes),
    onError: (Object error) => outputError ??= error,
    onDone: errorsDone.complete,
  );
  var exited = false;
  final exit = process.exitCode.then((code) {
    exited = true;
    return code;
  });
  var owned = false;
  var reading = true;
  var timedOut = false;
  Map<String, dynamic>? result;
  Object? failure;
  Future<void>? reader;
  Future<void> readState() async {
    while (reading) {
      final file = owned ? File('${control.path}/state.result') : stateFile;
      if (await file.exists()) {
        final state =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        if (!reading) return;
        if (state['state'] == 'ready' && !owned) {
          if (state['owner'] != process.pid) {
            throw StateError('Process owner handshake has the wrong PID.');
          }
          owned = true;
          if (clock.elapsed >= timeout) {
            throw TimeoutException(command, timeout);
          }
          process.stdin.writeln('start');
          await process.stdin.flush();
        } else if (state['state'] == 'exited' || state['state'] == 'error') {
          result = state;
          return;
        }
      }
      if (exited) {
        throw StateError('Process owner exited before reporting a result.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  try {
    final remaining = timeout - clock.elapsed;
    if (remaining <= Duration.zero) throw TimeoutException(command, timeout);
    reader = readState();
    await reader.timeout(remaining);
  } on TimeoutException {
    timedOut = true;
  } catch (error) {
    failure = error;
  } finally {
    reading = false;
    if (!exited) {
      if (owned && !Platform.isWindows) {
        if (timedOut) {
          Process.killPid(-process.pid, ProcessSignal.sigterm);
          // The owner keeps the group ID reserved during this grace period.
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        Process.killPid(-process.pid, ProcessSignal.sigkill);
      } else {
        // Before the handshake no command can start. On Windows, terminating
        // the owner closes the Job's only handle and terminates its children.
        process.kill(ProcessSignal.sigkill);
      }
    }
    try {
      await process.stdin.close();
    } catch (_) {
      // The owner may already have closed its control pipe during termination.
    }
    try {
      await Future.wait<Object?>([exit, outputDone.future, errorsDone.future])
          .timeout(const Duration(seconds: 5));
    } on TimeoutException {
      failure = StateError(
        'Owned process tree did not close its output pipes.',
      );
      await outputSubscription.cancel();
      await errorsSubscription.cancel();
    }
    await reader?.onError((_, _) {});
    await control.delete(recursive: true);
  }
  final stdout = utf8.decode(output.takeBytes(), allowMalformed: true);
  final stderr = utf8.decode(errors.takeBytes(), allowMalformed: true);
  final code = result?['code'] as int? ?? -1;
  final context =
      '$command\nOwner PID: ${process.pid}\n'
      'stdout:\n$stdout\nstderr:\n$stderr'
      '${result?['message'] == null ? '' : '\n${result!['message']}'}'
      '${outputError == null ? '' : '\nI/O error: $outputError'}'
      '${failure == null ? '' : '\n$failure'}';
  if (timedOut) {
    throw TimeoutException(
      '$context\nDeadline exceeded; '
      '${failure == null ? 'owned process tree stopped.' : 'process cleanup did not complete.'}',
      timeout,
    );
  }
  if (failure != null ||
      result?['state'] == 'error' ||
      outputError != null ||
      (checkExitCode && code != 0)) {
    throw ProcessException(executable, arguments, context, code);
  }
  return ProcessResult(
    result?['pid'] as int? ?? process.pid,
    code,
    stdout,
    stderr,
  );
}
