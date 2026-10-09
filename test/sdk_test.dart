import 'dart:convert';
import 'dart:io';

import 'package:napi/src/sdk.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  test(
    'Wasm conditions inherit libraries and respect overrides and support',
    () {
      final sdk = Directory.systemTemp.createTempSync('napi_sdk_');
      addTearDown(() => sdk.deleteSync(recursive: true));
      final lib = Directory(path.join(sdk.path, 'lib'))..createSync();
      File(path.join(lib.path, 'libraries.json')).writeAsStringSync(
        jsonEncode({
          'common': {
            'libraries': {
              'core': {'uri': 'core.dart'},
              'io': {'uri': 'io.dart'},
              'ffi': {'uri': 'ffi.dart'},
              '_internal': {'uri': 'internal.dart'},
            },
          },
          'web_common': {
            'include': [
              {'target': 'common'},
            ],
            'libraries': {
              'js_interop': {'uri': 'js_interop.dart'},
            },
          },
          'wasm': {
            'include': [
              {'target': 'web_common'},
            ],
            'libraries': {
              'io': {'uri': 'io.dart', 'support_conditional_import': false},
            },
          },
          'other': {
            'libraries': {
              'html': {'uri': 'html.dart'},
            },
          },
        }),
      );
      expect(wasmLibraryVariables(sdk.path), {
        'dart.library.core': 'true',
        'dart.library.js_interop': 'true',
      });
    },
  );
}
