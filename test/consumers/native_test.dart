import 'dart:io';

import 'package:napi/src/build/native_runtime.dart';
import 'package:test/test.dart';

import '../support/commands.dart';
import '../support/consumer.dart';
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
    test(
      'module rebuilds',
      () => consumer(
        (root) async =>
            verifyModuleRebuild(root, nativeRuntime: await runtime()),
      ),
    );
    test(
      'installed package',
      () => consumer((root) async {
        await verifyNativePackage(root, nativeRuntime: supplied);
        await HttpOverrides.runWithHttpOverrides(
          () => resolveNativeRuntime(runtime: supplied, output: root),
          _OfflineRuntime(),
        );
      }),
    );
    test(
      'dual-target package',
      () => consumer((root) async {
        await runtime();
        await HttpOverrides.runWithHttpOverrides(
          () => verifyDualTargetFixture(root, supplied),
          _OfflineRuntime(),
        );
      }),
    );
    test(
      'scalars',
      () => consumer(
        (root) async =>
            verifyNativeFunctionPackage(root, await runtime(), 'scalar'),
      ),
    );
    test(
      'arguments',
      () => consumer(
        (root) async =>
            verifyNativeFunctionPackage(root, await runtime(), 'argument'),
      ),
    );
    test(
      'value classes',
      () => consumer(
        (root) async =>
            verifyValueOnlyFixture(root, nativeRuntime: await runtime()),
      ),
    );
    test(
      'events',
      () => consumer(
        (root) async =>
            verifyNativeEvents(root, nativeRuntime: await runtime()),
      ),
    );
    test(
      'host values',
      () => consumer(
        (root) async =>
            verifyNativeHostValues(root, nativeRuntime: await runtime()),
      ),
    );
    test(
      'Futures',
      () => consumer(
        (root) async =>
            verifyFutureFixture(root, nativeRuntime: await runtime()),
      ),
    );
    test(
      'void',
      () => consumer(
        (root) async => verifyVoidFixture(root, nativeRuntime: await runtime()),
      ),
    );
    test(
      'resources',
      () => consumer(
        (root) async =>
            verifyResourceFixture(root, nativeRuntime: await runtime()),
      ),
    );
    test(
      'opaque payloads',
      () => consumer(
        (root) async =>
            verifyOpaqueFixture(root, nativeRuntime: await runtime()),
      ),
    );
    test(
      'Streams',
      () => consumer(
        (root) async =>
            verifyStreamFixture(root, nativeRuntime: await runtime()),
      ),
    );
    test(
      'cancellation',
      () => consumer(
        (root) async =>
            verifyCancellationFixture(root, nativeRuntime: await runtime()),
      ),
    );
    test(
      'binary',
      () => consumer(
        (root) async =>
            verifyBinaryFixture(root, nativeRuntime: await runtime()),
      ),
    );
    test(
      'concrete generics',
      () => consumer(
        (root) async =>
            verifyConcreteFixture(root, nativeRuntime: await runtime()),
      ),
    );
    test(
      'shared bytes',
      () => consumer(
        (root) async =>
            verifySharedBytesFixture(root, nativeRuntime: await runtime()),
      ),
    );
    test(
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
