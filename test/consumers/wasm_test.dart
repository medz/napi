import 'dart:io';

import 'package:test/test.dart';

import '../support/consumer.dart';
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
  setUpAll(reportNodeVersions);
  group('Wasm', () {
    test(
      'scalars',
      () => consumer((root) async {
        final output = Directory('${root.path}/scalars');
        await buildScalarFixture(output);
        await run('node', ['test.mjs'], cwd: output.path);
        await typescript(output, 'consumer.mts');
        await installedConsumer(output, root);
      }),
    );
    test(
      'arguments',
      () => consumer((root) async {
        final output = Directory('${root.path}/arguments');
        await buildArgumentFixture(output);
        await run('node', ['test.mjs'], cwd: output.path);
        await typescript(output, 'consumer.mts');
        await installedConsumer(output, root, fixture: 'arguments_package');
      }),
    );
    test(
      'structures',
      () => consumer((root) async {
        final output = Directory('${root.path}/structures');
        await buildStructuralFixture(output);
        await run('node', ['--expose-gc', 'test.mjs'], cwd: output.path);
        await typescript(output, 'consumer.mts');
        await installedConsumer(output, root, fixture: 'structural_package');
      }),
    );
    test('package assembly', () => consumer(verifyPackageAssembly));
    test('module rebuilds', () => consumer(verifyModuleRebuild));
    test(
      'classes',
      () => consumer((root) async {
        final sentinel = File('${root.path}/business/keep.txt');
        await sentinel.parent.create();
        await sentinel.writeAsString('unrelated user file');
        await verifyClassFixture(root);
        expect(await sentinel.readAsString(), 'unrelated user file');
      }),
    );
    test(
      'export kinds',
      () => consumer((root) async {
        final output = await buildExportKindFixture(
          output: Directory('${root.path}/exports'),
        );
        await run('node', ['test.mjs'], cwd: output.path);
        await typescript(output, 'consumer.mts');
      }),
    );
    test('Futures', () => consumer(verifyFutureFixture));
    test('void', () => consumer(verifyVoidFixture));
    test('resources', () => consumer(verifyResourceFixture));
    test('opaque payloads', () => consumer(verifyOpaqueFixture));
    test('Streams', () => consumer(verifyStreamFixture));
    test('cancellation', () => consumer(verifyCancellationFixture));
    test('binary', () => consumer(verifyBinaryFixture));
    test('concrete generics', () => consumer(verifyConcreteFixture));
    test('shared bytes', () => consumer(verifySharedBytesFixture));
    test('JS collections', () => consumer(verifyJsCollectionsFixture));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
