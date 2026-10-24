import 'dart:io';

import 'package:test/test.dart';

import 'consumer.dart';
import 'process.dart';

/// Keep direct build API calls and their compiler descendants in one owner.
void consumerTest(
  String name,
  Future<void> Function() body, {
  required String suite,
  required String group,
  Duration timeout = const Duration(minutes: 3),
}) {
  final fullName = '$group $name';
  final worker = Platform.environment['NAPI_CONSUMER_CASE'];
  if (worker != null) {
    if (worker == fullName) test(name, body);
    return;
  }
  test(
    name,
    () => consumer((root) async {
      await runProcess(
        Platform.resolvedExecutable,
        [
          'test',
          suite,
          '--name',
          '^${RegExp.escape(fullName)}\$',
          '--reporter',
          'expanded',
        ],
        timeout: timeout,
        environment: {
          'NAPI_CONSUMER_CASE': fullName,
          'NAPI_CONSUMER_ROOT': root.path,
        },
      );
    }),
    timeout: Timeout(timeout + const Duration(minutes: 1)),
  );
}
