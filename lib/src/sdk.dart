import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

/// The library conditions used by this SDK's default dart2wasm target.
Map<String, String> wasmLibraryVariables(String sdkPath) {
  final specification = jsonDecode(
    File(path.join(sdkPath, 'lib', 'libraries.json')).readAsStringSync(),
  ) as Map<String, dynamic>;
  final visiting = <String>{};
  Map<String, dynamic> librariesFor(String name) {
    final target = specification[name];
    if (target is! Map<String, dynamic> || !visiting.add(name)) {
      throw FormatException('Invalid Dart SDK library target: $name');
    }
    final libraries = <String, dynamic>{};
    for (final include in target['include'] as List<dynamic>? ?? []) {
      if (include['path'] != null) {
        throw const FormatException(
          'External Dart SDK library specifications are not supported.',
        );
      }
      libraries.addAll(librariesFor(include['target'] as String));
    }
    libraries.addAll(target['libraries'] as Map<String, dynamic>? ?? {});
    visiting.remove(name);
    return libraries;
  }

  final variables = <String, String>{};
  for (final library in librariesFor('wasm').entries) {
    final supported = library.value['support_conditional_import'] ?? true;
    if (supported is! bool) {
      throw FormatException('Invalid SDK library condition: ${library.key}');
    }
    // The compiler leaves unavailable library conditions undefined, not false.
    // dart2wasm disables ffi unless experimental FFI is explicitly enabled.
    if (supported && library.key != 'ffi' && !library.key.startsWith('_')) {
      variables['dart.library.${library.key}'] = 'true';
    }
  }
  return variables;
}
