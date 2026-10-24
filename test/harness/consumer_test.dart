import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../support/process.dart';

void main() {
  test(
    'consumer timeout stops raw subprocesses before deleting its root',
    () async {
      final directory = (await Directory(
        '.dart_tool',
      ).createTemp('consumer timeout 雪 ')).absolute;
      final rootFile = File('${directory.path}/consumer-root');
      addTearDown(() async {
        // Keep a failing cleanup regression from leaving the fixture running.
        await File('${directory.path}/stop').writeAsString('stop');
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (await rootFile.exists()) {
          final root = Directory(await rootFile.readAsString());
          if (await root.exists()) await root.delete(recursive: true);
        }
        await directory.delete(recursive: true);
      });

      final script = File('${directory.path}/tree.cjs');
      await script.writeAsString(r'''
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const [mode, evidence] = process.argv.slice(2);
process.on('SIGTERM', () => {});
setTimeout(() => process.exit(0), 10000).unref();
const stop = () => {
  if (fs.existsSync(path.join(evidence, 'stop'))) process.exit(0);
};
if (mode === 'grandchild') {
  const beat = () => {
    stop();
    fs.appendFileSync(path.join(evidence, 'heartbeat'), '.');
  };
  beat();
  setInterval(beat, 20);
} else {
  spawn(process.execPath, [__filename, 'grandchild', evidence], {
    stdio: 'inherit',
  });
  setInterval(stop, 20);
}
''');

      final suite = File('${directory.path}/timeout_test.dart');
      final registration = File('test/support/consumer_runner.dart')
          .absolute
          .uri;
      final consumer = File('test/support/consumer.dart').absolute.uri;
      final node = Platform.environment['NODE'] ?? 'node';
      await suite.writeAsString('''
import 'dart:io';
import 'package:test/test.dart';
import ${_literal(registration.toString())};
import ${_literal(consumer.toString())};

void main() {
  group('timeout fixture', () {
    consumerTest('raw process', () => consumer((root) async {
      await File(${_literal(rootFile.path)}).writeAsString(
        Platform.environment['NAPI_CONSUMER_ROOT']!,
      );
      await File.fromUri(root.uri.resolve('marker')).writeAsString('worker');
      print('consumer worker started');
      await Process.run(
        ${_literal(node)},
        [${_literal(script.path)}, 'child', ${_literal(directory.path)}],
        workingDirectory: root.path,
      );
    }), suite: ${_literal(suite.path)}, group: 'timeout fixture',
      timeout: const Duration(seconds: 6));
  });
}
''');

      final result = await runProcess(
        Platform.resolvedExecutable,
        ['test', suite.path, '--reporter', 'expanded'],
        timeout: const Duration(seconds: 40),
        checkExitCode: false,
      );
      expect(result.exitCode, greaterThan(0));
      final output = '${result.stdout}\n${result.stderr}';
      expect(output, contains('Deadline exceeded'));
      expect(output, contains('consumer worker started'));
      final root = Directory(await rootFile.readAsString());
      expect(await root.exists(), isFalse);

      final heartbeat = File('${directory.path}/heartbeat');
      final before = await heartbeat.length();
      expect(before, greaterThan(0));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(await heartbeat.length(), before);
    },
    timeout: const Timeout(Duration(seconds: 50)),
  );
}

String _literal(String value) => jsonEncode(value).replaceAll(r'$', r'\$');
