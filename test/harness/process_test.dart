import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

import '../support/process.dart';

void main() {
  final node = Platform.environment['NODE'] ?? 'node';
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi process 雪 ');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
  });

  test('drains both output streams before returning', () async {
    final result = await runProcess(
      node,
      [
        '-e',
        "process.stdout.write('a'.repeat(1024 * 1024)); process.stderr.write('b'.repeat(1024 * 1024));",
      ],
      timeout: const Duration(seconds: 10),
      workingDirectory: directory.path,
    );
    expect(result.stdout, 'a' * (1024 * 1024));
    expect(result.stderr, 'b' * (1024 * 1024));
  });

  test('an input-free child receives stdin EOF', () async {
    final result = await runProcess(node, [
      '-e',
      "process.stdin.on('end', () => console.log('EOF')); process.stdin.resume();",
    ], timeout: const Duration(seconds: 10));
    expect(result.stdout, 'EOF\n');
  });

  test('startup failure includes command and working directory', () async {
    final missing = '${directory.path}/missing-executable';
    await expectLater(
      runProcess(
        missing,
        ['argument'],
        timeout: const Duration(seconds: 10),
        workingDirectory: directory.path,
      ),
      throwsA(
        isA<ProcessException>().having(
          (error) => error.message,
          'diagnostics',
          allOf(
            contains(missing),
            contains('argument'),
            contains(directory.path),
          ),
        ),
      ),
    );
  });

  test(
    'nonzero exit includes command, directory and both output streams',
    () async {
      await expectLater(
        runProcess(
          node,
          [
            '-e',
            "console.log('before failure'); console.error('failure detail'); process.exitCode = 7;",
          ],
          timeout: const Duration(seconds: 10),
          workingDirectory: directory.path,
        ),
        throwsA(
          isA<ProcessException>()
              .having((error) => error.errorCode, 'exit code', 7)
              .having(
                (error) => error.message,
                'diagnostics',
                allOf(
                  contains(node),
                  contains(directory.path),
                  contains('before failure'),
                  contains('failure detail'),
                ),
              ),
        ),
      );
    },
  );

  test('timeout reports output discarded before the child hangs', () async {
    Object? failure;
    try {
      await runProcess(
        node,
        [
          '-e',
          "process.stdout.write('x'.repeat(5 * 1024 * 1024)); setInterval(() => {}, 1000);",
        ],
        timeout: const Duration(seconds: 2),
        workingDirectory: directory.path,
      );
    } catch (error) {
      failure = error;
    }
    expect(failure, isA<TimeoutException>());
    final message = (failure as TimeoutException).message ?? '';
    expect(message.contains('direct child has exited'), isTrue);
    expect(
      message.contains(
        'Output exceeded 4 MiB per stream; remaining bytes discarded.',
      ),
      isTrue,
      reason: 'A timeout must disclose that its captured output was truncated.',
    );
    expect(message.length, lessThan(4 * 1024 * 1024 + 4096));
  });

  for (final ignoreTerm in [false, true]) {
    test('timeout reaps a child before cleanup (ignore SIGTERM: $ignoreTerm)', () async {
      final pidFile = File('${directory.path}/pid');
      // The child records its own PID before hanging, so the independent probe
      // below verifies the process is gone after the timeout has completed.
      final script =
          "require('node:fs').writeFileSync('pid', String(process.pid)); "
          "${ignoreTerm ? "process.on('SIGTERM', () => {}); " : ''}"
          "console.log('started'); setInterval(() => {}, 1000);";
      Object? failure;
      try {
        await runProcess(
          node,
          ['-e', script],
          timeout: const Duration(seconds: 1),
          workingDirectory: directory.path,
        );
      } catch (error) {
        failure = error;
      }
      expect(
        failure,
        isA<TimeoutException>().having(
          (error) => error.message,
          'diagnostics',
          allOf(
            contains(directory.path),
            contains('started'),
            contains('direct child has exited'),
          ),
        ),
      );
      final pid = int.parse(await pidFile.readAsString());
      await runProcess(node, [
        '-e',
        "try { process.kill($pid, 0); process.exitCode = 1; } catch (error) { if (error.code !== 'ESRCH') throw error; }",
      ], timeout: const Duration(seconds: 10));
      await directory.delete(recursive: true);
      expect(await directory.exists(), isFalse);
    });
  }
}
