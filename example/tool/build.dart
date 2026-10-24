import 'dart:io';

import 'package:napi/build.dart';

final package = PackageBuild(
  library: File('lib/counter.dart').absolute.uri,
  output: Directory('npm-package'),
  name: 'dart-counter',
  version: '0.0.0',
  target: BuildTarget.wasm,
);

Future<void> main(List<String> args) => package.run(args);
