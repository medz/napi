import 'dart:io';
import 'dart:convert';

import 'package:napi/src/build/fixture_compiler.dart';
import 'package:napi/src/build/fixture_runner.dart';

Future<void> main(List<String> arguments) async {
  final root = Directory.current.path;
  final source = File('$root/test/fixtures/primitives.dart');
  final originalSource = base64Encode(await source.readAsBytes());
  final parent = Directory('$root/.dart_tool/napi-fixtures');
  await parent.create(recursive: true);
  final prior = await parent.createTemp('prior-output-');
  final sentinel = File('${prior.path}/preserve-me');
  await sentinel.writeAsString('Unrelated existing output must survive.\n');
  final package = await FixtureCompiler().build(
    projectRoot: root,
    sourcePath: '$root/test/fixtures/primitives.dart',
    functionNames: [
      'add',
      'echoInt',
      'echoDouble',
      'negate',
      'echoString',
      'accept',
      'unsafeOutput',
      'unsafeConditionalOutput',
      'echoConditional',
      'fail',
      'failBadMessage',
      'failBadType',
      'failArgumentMessage',
      'api',
      r'$echo',
    ],
  );
  if (base64Encode(await source.readAsBytes()) != originalSource ||
      await sentinel.readAsString() !=
          'Unrelated existing output must survive.\n') {
    throw StateError('Fixture build changed source or unrelated output.');
  }
  stdout.writeln('Source and existing-output preservation passed.');
  stdout.writeln('Compiled fixture: ${package.path}');
  if (arguments.contains('--compile-only')) return;
  await runFixtureChecks(
    projectRoot: root,
    package: package,
    node: Platform.environment['NAPI_NODE'] ?? 'node',
    bun: Platform.environment['NAPI_BUN'] ?? 'bun',
    npm: Platform.environment['NAPI_NPM'] ?? 'npm',
    tsc: Platform.environment['NAPI_TSC'] ?? 'tsc',
  );
}
