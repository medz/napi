import 'dart:io';

import 'package:napi/compiler.dart';

Future<void> main(List<String> args) async {
  final source = File.fromUri(Platform.script).parent;
  final output = Directory(args.single);
  await Compiler([
    for (final (profile, entry) in [
      ('core', 'counter.dart'),
      ('regexp', 'regexp.dart'),
      ('full', 'payload.dart'),
      ('failed', 'failed_registration.dart'),
    ])
      NativeTarget(
        entry: File('${source.path}/$entry'),
        output: File('${output.path}/$profile/addon.node'),
      ),
  ]).run([]);

  final core = File('${output.path}/core/addon.node');
  final original = await core.readAsBytes();
  final temporary = await source.createTemp('.entrypoint-');
  try {
    final entry = File('${temporary.path}/addon.dart');
    for (final (declaration, expected) in [
      (
        'void register(Env env, JsObject exports) async {}',
        'must be synchronous void register(Env env, JsObject exports)',
      ),
      (
        'void register(int env, int exports) {}',
        'must declare void register(Env env, JsObject exports)',
      ),
    ]) {
      await entry.writeAsString(
        "import 'package:napi/env.dart';\n$declaration\n",
      );
      String? failure;
      try {
        await Compiler([NativeTarget(entry: entry, output: core)]).run([]);
      } on StateError catch (error) {
        failure = error.message.toString();
      }
      if (failure == null || !failure.contains(expected)) {
        throw StateError('Expected register signature rejection, got $failure');
      }
      final current = await core.readAsBytes();
      if (current.length != original.length ||
          original.indexed.any((byte) => current[byte.$1] != byte.$2)) {
        throw StateError('Invalid register entry changed the existing addon');
      }
    }
  } finally {
    await temporary.delete(recursive: true);
  }
  await Compiler([
    NativeTarget(entry: File('${source.path}/counter.dart'), output: core),
  ]).run([]);
}
