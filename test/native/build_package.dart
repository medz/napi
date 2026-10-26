import 'dart:io';

import 'package:napi/compiler.dart';

Future<void> main(List<String> args) async {
  final entry = File(args[0]).absolute;
  final output = Directory(args[1]).absolute;

  Future<void> build(File source) => Compiler([
    PackageBuild(
      entry: source,
      output: output,
      name: '@fixture/counter',
      version: '0.0.0',
    ),
  ]).run([]);

  await build(entry);
  final previous = <String, List<int>>{
    for (final name in [
      'addon.node',
      'index.cjs',
      'index.mjs',
      'index.d.cts',
      'index.d.mts',
      'package.json',
      'NOTICES',
      '.napi.json',
    ])
      name: await File('${output.path}/$name').readAsBytes(),
  };
  final invalid = await entry.parent.createTemp('.package-invalid-');
  try {
    final external = File('${invalid.path}/keep.txt');
    await external.writeAsString('outside package output');
    final source = File('${invalid.path}/addon.dart');
    await source.writeAsString(
      "import 'package:napi/napi.dart';\n"
      'class Hidden {}\n'
      '@NAPI() Hidden unsupported() => Hidden();\n',
    );
    String? failure;
    try {
      await build(source);
    } on StateError catch (error) {
      failure = error.message.toString();
    }
    if (failure == null || !failure.contains('class type must be exported')) {
      throw StateError(
        'Expected invalid package entry rejection, got $failure',
      );
    }
    for (final file in previous.entries) {
      final current = await File('${output.path}/${file.key}').readAsBytes();
      if (current.length != file.value.length ||
          file.value.indexed.any((byte) => current[byte.$1] != byte.$2)) {
        throw StateError('Failed package rebuild changed ${file.key}');
      }
    }
    final foreign = File('${output.path}/user.txt');
    await foreign.writeAsString('user-owned file');
    var rejected = false;
    try {
      await build(entry);
    } on StateError {
      rejected = true;
    }
    if (!rejected || await foreign.readAsString() != 'user-owned file') {
      throw StateError('Package rebuild did not preserve an unknown file');
    }
    await foreign.delete();
    await build(entry);
    if (await external.readAsString() != 'outside package output') {
      throw StateError('Package rebuild changed a file outside its output');
    }
  } finally {
    await invalid.delete(recursive: true);
  }
}
