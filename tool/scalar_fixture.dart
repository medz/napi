import 'dart:io';

import 'package:napi/build.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';

Future<BindingModule> scalarBindings() =>
    const AnnotationFrontend(packagesPath: '.dart_tool/package_config.json')
        .read(File('test/fixtures/scalar_exports.dart').absolute.uri);

Future<void> buildScalarFixture(Directory output) async {
  await buildLibrary(
    library: File('test/fixtures/scalar_exports.dart').absolute.uri,
    output: output,
    packagesPath: '.dart_tool/package_config.json',
  );
  for (final entry in {
    'test/integration/scalars.mjs': 'test.mjs',
    'test/typescript/scalars.mts': 'consumer.mts',
  }.entries) {
    await File(entry.key).copy('${output.path}/${entry.value}');
  }
}

Future<void> main(List<String> args) async {
  await buildScalarFixture(Directory(args.single));
}
