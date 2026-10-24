import 'dart:async';
import 'dart:convert';
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

  test('expected nonzero exit retains code and both streams', () async {
    final result = await runProcess(
      node,
      [
        '-e',
        "console.log('expected output'); console.error('expected failure'); process.exitCode = 7;",
      ],
      timeout: const Duration(seconds: 10),
      workingDirectory: directory.path,
      checkExitCode: false,
    );
    expect(result.exitCode, 7);
    expect(result.stdout, 'expected output\n');
    expect(result.stderr, 'expected failure\n');
  });

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
    expect(message.contains('Deadline exceeded'), isTrue);
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
            contains('Deadline exceeded'),
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

  for (final ignoreTerm in [false, true]) {
    test(
      'timeout stops children and grandchildren (ignore SIGTERM: $ignoreTerm)',
      () async {
        await _writeProcessTree(directory);
        await expectLater(
          runProcess(
            node,
            ['tree-parent.cjs', 'wait', 'inherit', '$ignoreTerm'],
            timeout: const Duration(seconds: 3),
            workingDirectory: directory.path,
          ),
          throwsA(
            isA<TimeoutException>().having(
              (error) => error.message,
              'diagnostics',
              allOf(
                contains('Deadline exceeded'),
                contains('parent ready'),
                contains('grandchild output'),
                contains('grandchild error'),
              ),
            ),
          ),
        );
        await _expectHeartbeatStopped(directory, 'child-heartbeat');
        await _expectHeartbeatStopped(directory, 'grandchild-heartbeat');
      },
    );
  }

  for (final output in ['inherit', 'ignore']) {
    test('normal exit cleans descendants with $output output', () async {
      await _writeProcessTree(directory);
      final result = await runProcess(
        node,
        ['tree-parent.cjs', 'exit', output, 'false'],
        timeout: const Duration(seconds: 10),
        workingDirectory: directory.path,
      );
      expect(result.exitCode, 0);
      expect(result.stdout, contains('parent ready'));
      if (output == 'inherit') {
        expect(result.stdout, contains('grandchild output'));
        expect(result.stderr, contains('grandchild error'));
      }
      await _expectHeartbeatStopped(directory, 'child-heartbeat');
      await _expectHeartbeatStopped(directory, 'grandchild-heartbeat');
    });
  }

  test('timed-out process tree leaves an unrelated process running', () async {
    await _writeProcessTree(directory);
    final unrelated = await Process.start(node, [
      '-e',
      "const fs = require('node:fs'); "
          "const beat = () => fs.appendFileSync('unrelated-heartbeat', '.'); "
          "beat(); console.log('ready'); setInterval(beat, 20);",
    ], workingDirectory: directory.path);
    final unrelatedErrors = unrelated.stderr.transform(utf8.decoder).join();
    addTearDown(() async {
      unrelated.kill(ProcessSignal.sigkill);
      await unrelated.exitCode.timeout(const Duration(seconds: 5));
      await unrelatedErrors;
    });
    await unrelated.stdin.close();
    expect(
      await unrelated.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 5)),
      'ready',
    );
    await expectLater(
      runProcess(
        node,
        ['tree-parent.cjs', 'wait', 'inherit', 'false'],
        timeout: const Duration(seconds: 3),
        workingDirectory: directory.path,
      ),
      throwsA(isA<TimeoutException>()),
    );
    final unrelatedHeartbeat = File('${directory.path}/unrelated-heartbeat');
    final before = await unrelatedHeartbeat.length();
    await _expectHeartbeatStopped(directory, 'grandchild-heartbeat');
    expect(await unrelatedHeartbeat.length(), greaterThan(before));
  });
}

Future<void> _expectHeartbeatStopped(Directory directory, String name) async {
  final heartbeat = File('${directory.path}/$name');
  final before = await heartbeat.length();
  expect(before, greaterThan(0), reason: '$name must have started.');
  await Future<void>.delayed(const Duration(milliseconds: 300));
  expect(
    await heartbeat.length(),
    before,
    reason: '$name must stop before runProcess completes.',
  );
}

Future<void> _writeProcessTree(Directory directory) async {
  addTearDown(() async {
    // Also clean up after a failing assertion against an older helper.
    await File('${directory.path}/stop').writeAsString('stop');
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });
  final scripts = {
    'tree-parent.cjs': r'''
const fs = require('node:fs');
const { fork } = require('node:child_process');
const [mode, output, ignoreTerm] = process.argv.slice(2);
if (ignoreTerm === 'true') process.on('SIGTERM', () => {});
setTimeout(() => process.exit(0), 10000).unref();
const child = fork('./tree-child.cjs', [ignoreTerm], {
  stdio: ['ignore', output, output, 'ipc'],
});
child.on('message', () => {
  fs.writeSync(1, 'parent ready\n');
  if (mode === 'exit') process.exit(0);
});
setInterval(() => {
  if (fs.existsSync('stop')) process.exit(0);
}, 20);
''',
    'tree-child.cjs': r'''
const fs = require('node:fs');
const { fork } = require('node:child_process');
const ignoreTerm = process.argv[2];
if (ignoreTerm === 'true') process.on('SIGTERM', () => {});
setTimeout(() => process.exit(0), 10000).unref();
const beat = () => {
  if (fs.existsSync('stop')) process.exit(0);
  fs.appendFileSync('child-heartbeat', '.');
};
beat();
setInterval(beat, 20);
const grandchild = fork('./tree-grandchild.cjs', [ignoreTerm], {
  stdio: ['ignore', 'inherit', 'inherit', 'ipc'],
});
grandchild.on('message', () => process.send('ready'));
''',
    'tree-grandchild.cjs': r'''
const fs = require('node:fs');
if (process.argv[2] === 'true') process.on('SIGTERM', () => {});
setTimeout(() => process.exit(0), 10000).unref();
const beat = () => {
  if (fs.existsSync('stop')) process.exit(0);
  fs.appendFileSync('grandchild-heartbeat', '.');
};
beat();
setInterval(beat, 20);
fs.writeSync(1, 'grandchild output\n');
fs.writeSync(2, 'grandchild error\n');
process.send('ready');
''',
  };
  for (final entry in scripts.entries) {
    await File('${directory.path}/${entry.key}').writeAsString(entry.value);
  }
}
