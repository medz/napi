import 'dart:io';

import 'package:napi/compiler.dart';

final compiler = Compiler([
  NativeTarget(
    entry: File('example/counter.dart'),
    output: File('build/counter.node'),
  ),
]);

Future<void> main(List<String> args) => compiler.run(args);
