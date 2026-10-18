import 'dart:io';

import 'package:napi/src/build/native_bundle.dart';
import 'package:napi/src/build/publish.dart';

/// Distribution tools reuse the application builder's exact profile checks.
Future<void> main(List<String> args) async {
  if (args.isEmpty || args.length > 2) {
    throw ArgumentError(
      'Usage: dart run tool/native/verify_bundle.dart <bundle> [publish-directory]',
    );
  }
  final source = Directory(args.first);
  await NativeRuntimeBundle.read(source);
  if (args.length == 2) publishDirectory(source, Directory(args[1]));
}
