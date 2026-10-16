import 'dart:io';

import 'package:napi/build.dart';

Future<void> buildStructuralFixture(Directory output) async {
  await buildLibrary(
    library: File('test/fixtures/structural_values.dart').absolute.uri,
    output: output,
    packagesPath: '.dart_tool/package_config.json',
  );
  for (final entry in {
    'test/integration/structural_values.mjs': 'test.mjs',
    'test/integration/structural_contract.mjs': 'structural_contract.mjs',
    'test/typescript/structural_values.mts': 'consumer.mts',
  }.entries) {
    await File(entry.key).copy('${output.path}/${entry.value}');
  }
}

Future<void> main(List<String> args) async {
  await buildStructuralFixture(Directory(args.single));
}
