import 'dart:convert';
import 'dart:io';

import 'package:napi/compiler.dart';

Future<void> main(List<String> args) async {
  final manifests = [
    for (final path in args.take(args.length - 1)) File(path).absolute,
  ];
  final output = Directory(args.last).absolute;

  Future<void> assemble(List<File> inputs) => Compiler([
    PackageBuild.fromArtifacts(
      artifacts: [for (final input in inputs) NativeArtifact(input)],
      output: output,
      name: '@fixture/counter',
      version: '0.0.0',
    ),
  ]).run([]);

  await assemble(manifests);
  final previous = <File, List<int>>{};
  await for (final entity in output.list(recursive: true, followLinks: false)) {
    if (entity is File) previous[entity] = await entity.readAsBytes();
  }
  final originals = <File, String>{
    for (final manifest in manifests) manifest: await manifest.readAsString(),
  };
  final first = manifests.first;
  final invalid = await first.parent.parent.createTemp('.artifact-invalid-');
  try {
    await for (final entity in first.parent.list(followLinks: false)) {
      if (entity is File) {
        await entity.copy('${invalid.path}/${entity.uri.pathSegments.last}');
      }
    }
    final tampered = File('${invalid.path}/.napi.json');
    final data =
        jsonDecode(await tampered.readAsString()) as Map<String, dynamic>;
    (data['binary'] as Map<String, dynamic>)['sha256'] = ''.padLeft(64, '0');
    await tampered.writeAsString(jsonEncode(data));
    String? failure;
    try {
      await assemble([tampered, ...manifests.skip(1)]);
    } on FormatException catch (error) {
      failure = error.message;
    }
    if (failure == null || !failure.contains('content has changed')) {
      throw StateError('Expected artifact hash rejection, got $failure');
    }
    for (final file in previous.entries) {
      final current = await file.key.readAsBytes();
      if (current.length != file.value.length ||
          file.value.indexed.any((byte) => current[byte.$1] != byte.$2)) {
        throw StateError('Rejected artifact changed ${file.key.path}');
      }
    }
    final foreign = File('${output.path}/user.txt');
    await foreign.writeAsString('user-owned file');
    failure = null;
    try {
      await assemble(manifests);
    } on StateError catch (error) {
      failure = error.message.toString();
    }
    if (failure == null ||
        !failure.contains('unowned file') ||
        await foreign.readAsString() != 'user-owned file') {
      throw StateError('Assembly did not preserve an unknown file: $failure');
    }
    await foreign.delete();
    await assemble(manifests);
    for (final original in originals.entries) {
      if (await original.key.readAsString() != original.value) {
        throw StateError('Assembly changed its source artifact');
      }
    }
  } finally {
    await invalid.delete(recursive: true);
  }
}
