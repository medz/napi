import 'dart:io';

import 'package:test/test.dart';

import '../support/consumer.dart';
import '../support/consumer_runner.dart' as owned;
import '../support/commands.dart';
import '../support/package.dart';
import '../support/fixtures/arguments.dart';
import '../support/fixtures/scalars.dart';
import '../support/fixtures/structural.dart';
import '../support/fixtures/packages.dart';
import '../support/fixtures/classes.dart';
import '../support/fixtures/export_kinds.dart';
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
        suite: 'test/consumers/wasm_test.dart',
        group: 'Wasm',
      );
  setUpAll(reportNodeVersions);
  group('Wasm', () {
    testConsumer(
      'scalars',
      () => consumer((root) async {
        final output = Directory('${root.path}/scalars');
        await buildScalarFixture(output);
        await run('node', ['test.mjs'], cwd: output.path);
        await typescript(output, 'consumer.mts');
        await installedConsumer(output, root);
      }),
    );
    testConsumer(
      'arguments',
      () => consumer((root) async {
        final output = Directory('${root.path}/arguments');
        await buildArgumentFixture(output);
        await run('node', ['test.mjs'], cwd: output.path);
        await typescript(output, 'consumer.mts');
        await installedConsumer(output, root, fixture: 'arguments_package');
      }),
    );
    testConsumer(
      'structures',
      () => consumer((root) async {
        final output = Directory('${root.path}/structures');
        await buildStructuralFixture(output);
        await run('node', ['--expose-gc', 'test.mjs'], cwd: output.path);
        await typescript(output, 'consumer.mts');
        await installedConsumer(output, root, fixture: 'structural_package');
      }),
    );
    testConsumer('package assembly', () => consumer(verifyPackageAssembly));
    testConsumer('module rebuilds', () => consumer(verifyModuleRebuild));
    testConsumer(
      'classes',
      () => consumer((root) async {
        final sentinel = File('${root.path}/business/keep.txt');
        await sentinel.parent.create();
        await sentinel.writeAsString('unrelated user file');
        await verifyClassFixture(root);
        expect(await sentinel.readAsString(), 'unrelated user file');
      }),
    );
    testConsumer(
      'export kinds',
      () => consumer((root) async {
        final output = await buildExportKindFixture(
          output: Directory('${root.path}/exports'),
        );
        await run('node', ['test.mjs'], cwd: output.path);
        await typescript(output, 'consumer.mts');
      }),
    );
    testConsumer('Futures', () => consumer(verifyFutureFixture));
    testConsumer('void', () => consumer(verifyVoidFixture));
    testConsumer('resources', () => consumer(verifyResourceFixture));
    testConsumer('opaque payloads', () => consumer(verifyOpaqueFixture));
    testConsumer('Streams', () => consumer(verifyStreamFixture));
    testConsumer('cancellation', () => consumer(verifyCancellationFixture));
    testConsumer('binary', () => consumer(verifyBinaryFixture));
    testConsumer('concrete generics', () => consumer(verifyConcreteFixture));
    testConsumer('shared bytes', () => consumer(verifySharedBytesFixture));
    testConsumer('JS collections', () => consumer(verifyJsCollectionsFixture));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
