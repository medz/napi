import 'dart:io';

import 'package:napi/build.dart';

Future<void> buildArgumentFixture(Directory output) async {
  await buildLibrary(
    library: File('test/fixtures/arguments.dart').absolute.uri,
    output: output,
    packagesPath: '.dart_tool/package_config.json',
  );
  for (final entry in {
    'test/integration/argument_contract.mjs': 'argument_contract.mjs',
    'test/integration/arguments.mjs': 'test.mjs',
    'test/typescript/arguments.mts': 'consumer.mts',
  }.entries) {
    await File(entry.key).copy('${output.path}/${entry.value}');
  }
}
