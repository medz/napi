import 'dart:io';

import 'package:napi/src/build/build.dart';
import 'package:napi/src/compiler/ir/model.dart';

BindingModule scalarBindings() {
  final source = File('test/fixtures/scalars.dart').absolute.uri;
  FunctionBinding function(String name, List<String> names, {String? export}) =>
      FunctionBinding(
        declaration: DeclarationId(source, name),
        exportName: export ?? name,
        source: SourceLocation(source, 0, 0),
        parameters: [
          for (final name in names) ParameterBinding(name, const SafeIntType()),
        ],
        result: const SafeIntType(),
      );
  return BindingModule(
    source: source,
    functions: [
      function('add', ['a', 'b']),
      function('calls', []),
      function('echo', ['value']),
      function('fail', ['mode']),
      function('eval', ['arguments'], export: 'evaluate'),
      function('arguments', ['eval'], export: 'argumentCount'),
    ],
  );
}

Future<void> buildScalarFixture(Directory output) async {
  await buildModule(
    bindings: scalarBindings(),
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
