import 'package:napi/env.dart';

import 'counter.dart' as counter;

void register(Env env, JsObject exports) {
  final letters = RegExp(r'^\p{L}+$', unicode: true);
  if (!letters.hasMatch('你好Abc') ||
      letters.hasMatch('abc123') ||
      'abcσ'.toUpperCase() != 'ABCΣ') {
    throw StateError('Unicode RegExp or case conversion failed');
  }
  if (Uri.file(r'C:\hello world\你好.txt', windows: true).toString() !=
          'file:///C:/hello%20world/%E4%BD%A0%E5%A5%BD.txt' ||
      Uri.directory(r'\\server\share\目录', windows: true).toString() !=
          'file://server/share/%E7%9B%AE%E5%BD%95/' ||
      Uri.file(r'relative\a.txt', windows: true).toString() !=
          'relative/a.txt') {
    throw StateError('Windows drive, UNC or Unicode path conversion failed');
  }
  for (final code in [34, 42, 47, 58, 60, 62, 63, 92, 124]) {
    final invalid = Uri(pathSegments: ['a${String.fromCharCode(code)}b']);
    try {
      invalid.toFilePath(windows: true);
      throw StateError('Reserved Windows path character accepted: $code');
    } on UnsupportedError {
      // URI-to-path conversion reports an unsupported representation.
    }
  }
  for (final code in [34, 42, 58, 60, 62, 63, 124]) {
    try {
      Uri.file('C:\\a${String.fromCharCode(code)}b', windows: true);
      throw StateError('Invalid Windows file argument accepted: $code');
    } on ArgumentError {
      // File construction reports an invalid caller argument.
    }
  }
  counter.register(env, exports);
}
