import 'dart:io';

import 'package:napi/compiler.dart';

final compiler = Compiler([
  NativeTarget(
    entry: File('example/counter.dart'),
    output: File('build/counter.node'),
    declarations: File('build/counter.d.ts'),
  ),
]);

Future<void> main(List<String> args) => compiler.run(args);
