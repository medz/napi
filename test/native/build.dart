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
    ])
      NativeTarget(
        entry: File('${source.path}/$entry'),
        output: File('${output.path}/$profile/addon.node'),
      ),
  ]).run([]);
}
