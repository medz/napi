import 'dart:io';

import 'package:napi/src/build/native_runtime.dart';
import 'package:test/test.dart';

import '../support/commands.dart';
import '../support/consumer.dart';
import '../support/consumer_runner.dart' as owned;
import '../support/fixtures/native_packages.dart';
import '../support/fixtures/native_events.dart';
import '../support/fixtures/native_host_values.dart';
import '../support/fixtures/dual_targets.dart';
import '../support/fixtures/values.dart';
import '../support/fixtures/futures.dart';
import '../support/fixtures/void.dart';
import '../support/fixtures/resources.dart';
import '../support/fixtures/opaque.dart';
import '../support/fixtures/streams.dart';
import '../support/fixtures/cancellation.dart';
import '../support/fixtures/binary.dart';
import '../support/fixtures/concrete.dart';
import '../support/fixtures/shared_bytes.dart';
import '../support/fixtures/js_collections.dart';
import '../support/fixtures/module_rebuilds.dart';

void main() {
  void testConsumer(String name, Future<void> Function() body) =>
      owned.consumerTest(
        name,
        body,
        suite: 'test/consumers/native_test.dart',
        group: 'Native',
      );
  final configured = Platform.environment['NAPI_TEST_NATIVE_RUNTIME'];
  final supplied = configured == null ? null : Directory(configured);
  Future<Directory>? resolved;
  Future<Directory> runtime() => resolved ??= () async {
    late Directory directory;
    await consumer((root) async {
      directory = (await resolveNativeRuntime(
        runtime: supplied,
        output: root,
      )).directory;
    });
    return directory;
  }();
  setUpAll(() async {
    if (configured != null && configured.isEmpty) {
      throw StateError('NAPI_TEST_NATIVE_RUNTIME must not be empty.');
    }
    await reportNodeVersions();
  });
  group('Native', () {
    testConsumer(
      'module rebuilds',
      () => consumer(
        (root) async =>
            verifyModuleRebuild(root, nativeRuntime: await runtime()),
      ),
    );
    testConsumer(
      'installed package',
      () => consumer((root) async {
        await verifyNativePackage(root, nativeRuntime: supplied);
        await HttpOverrides.runWithHttpOverrides(
          () => resolveNativeRuntime(runtime: supplied, output: root),
          _OfflineRuntime(),
        );
      }),
    );
    testConsumer(
      'dual-target package',
      () => consumer((root) async {
        await runtime();
        await HttpOverrides.runWithHttpOverrides(
          () => verifyDualTargetFixture(root, supplied),
          _OfflineRuntime(),
        );
      }),
    );
    testConsumer(
      'scalars',
      () => consumer(
        (root) async =>
            verifyNativeFunctionPackage(root, await runtime(), 'scalar'),
      ),
    );
    testConsumer(
      'arguments',
      () => consumer(
        (root) async =>
            verifyNativeFunctionPackage(root, await runtime(), 'argument'),
      ),
    );
    testConsumer(
      'value classes',
      () => consumer(
        (root) async =>
            verifyValueOnlyFixture(root, nativeRuntime: await runtime()),
      ),
    );
    testConsumer(
      'events',
      () => consumer(
        (root) async =>
            verifyNativeEvents(root, nativeRuntime: await runtime()),
      ),
    );
    testConsumer(
      'host values',
      () => consumer(
        (root) async =>
            verifyNativeHostValues(root, nativeRuntime: await runtime()),
      ),
    );
    testConsumer(
      'Futures',
      () => consumer(
        (root) async =>
            verifyFutureFixture(root, nativeRuntime: await runtime()),
      ),
    );
    testConsumer(
      'void',
      () => consumer(
        (root) async => verifyVoidFixture(root, nativeRuntime: await runtime()),
      ),
    );
    testConsumer(
      'resources',
      () => consumer(
        (root) async =>
            verifyResourceFixture(root, nativeRuntime: await runtime()),
      ),
    );
    testConsumer(
      'opaque payloads',
      () => consumer(
        (root) async =>
            verifyOpaqueFixture(root, nativeRuntime: await runtime()),
      ),
    );
    testConsumer(
      'Streams',
      () => consumer(
        (root) async =>
            verifyStreamFixture(root, nativeRuntime: await runtime()),
      ),
    );
    testConsumer(
      'cancellation',
      () => consumer(
        (root) async =>
            verifyCancellationFixture(root, nativeRuntime: await runtime()),
      ),
    );
    testConsumer(
      'binary',
      () => consumer(
        (root) async =>
            verifyBinaryFixture(root, nativeRuntime: await runtime()),
      ),
    );
    testConsumer(
      'concrete generics',
      () => consumer(
        (root) async =>
            verifyConcreteFixture(root, nativeRuntime: await runtime()),
      ),
    );
    testConsumer(
      'shared bytes',
      () => consumer(
        (root) async =>
            verifySharedBytesFixture(root, nativeRuntime: await runtime()),
      ),
    );
    testConsumer(
      'JS collections',
      () => consumer(
        (root) async =>
            verifyJsCollectionsFixture(root, nativeRuntime: await runtime()),
      ),
    );
  }, timeout: const Timeout(Duration(minutes: 3)));
}

final class _OfflineRuntime extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => throw StateError(
    'Packages must reuse the verified native runtime cache offline.',
  );
}
