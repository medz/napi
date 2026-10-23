import 'dart:io';

Future<void> consumer(Future<void> Function(Directory) body) async {
  final root = await Directory('.dart_tool').createTemp('consumer ');
  try {
    await body(root.absolute);
  } finally {
    await root.delete(recursive: true);
  }
}
