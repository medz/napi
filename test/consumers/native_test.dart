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
  late Directory runtime;
  setUpAll(() async {
    if (configured != null && configured.isEmpty) {
      throw StateError('NAPI_TEST_NATIVE_RUNTIME must not be empty.');
    }
    await reportNodeVersions();
    await consumer((root) async {
      runtime = (await resolveNativeRuntime(
        runtime: supplied,
        output: root,
      )).directory;
    });
  });
  group('Native', () {
    test(
      'module rebuilds',
      () =>
          consumer((root) => verifyModuleRebuild(root, nativeRuntime: runtime)),
    );
    test(
      'installed package',
      () => consumer(
        (root) => verifyNativePackage(root, nativeRuntime: supplied),
      ),
    );
    test(
      'scalars',
      () => consumer(
        (root) => verifyNativeFunctionPackage(root, runtime, 'scalar'),
      ),
    );
    test(
      'arguments',
      () => consumer(
        (root) => verifyNativeFunctionPackage(root, runtime, 'argument'),
      ),
    );
    test(
      'value classes',
      () => consumer(
        (root) => verifyValueOnlyFixture(root, nativeRuntime: runtime),
      ),
    );
    test(
      'events',
      () =>
          consumer((root) => verifyNativeEvents(root, nativeRuntime: runtime)),
    );
    test(
      'host values',
      () => consumer(
        (root) => verifyNativeHostValues(root, nativeRuntime: runtime),
      ),
    );
    test(
      'Futures',
      () =>
          consumer((root) => verifyFutureFixture(root, nativeRuntime: runtime)),
    );
    test(
      'void',
      () => consumer((root) => verifyVoidFixture(root, nativeRuntime: runtime)),
    );
    test(
      'resources',
      () => consumer(
        (root) => verifyResourceFixture(root, nativeRuntime: runtime),
      ),
    );
    test(
      'opaque payloads',
      () =>
          consumer((root) => verifyOpaqueFixture(root, nativeRuntime: runtime)),
    );
    test(
      'Streams',
      () =>
          consumer((root) => verifyStreamFixture(root, nativeRuntime: runtime)),
    );
    test(
      'cancellation',
      () => consumer(
        (root) => verifyCancellationFixture(root, nativeRuntime: runtime),
      ),
    );
    test(
      'binary',
      () =>
          consumer((root) => verifyBinaryFixture(root, nativeRuntime: runtime)),
    );
    test(
      'concrete generics',
      () => consumer(
        (root) => verifyConcreteFixture(root, nativeRuntime: runtime),
      ),
    );
    test(
      'shared bytes',
      () => consumer(
        (root) => verifySharedBytesFixture(root, nativeRuntime: runtime),
      ),
    );
    test(
      'JS collections',
      () => consumer(
        (root) => verifyJsCollectionsFixture(root, nativeRuntime: runtime),
      ),
    );
    test(
      'dual-target package',
      () => consumer(
        (root) => HttpOverrides.runWithHttpOverrides(
          () => verifyDualTargetFixture(root, supplied),
          _OfflineRuntime(),
        ),
      ),
    );
  }, timeout: const Timeout(Duration(minutes: 3)));
}

final class _OfflineRuntime extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => throw StateError(
    'Dual packages must reuse the verified native runtime cache offline.',
  );
}
