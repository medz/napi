typedef Profile = ({int count, String name});

Profile echoProfile(Profile value) {
  if (!const bool.fromEnvironment('dart.library.core') ||
      !const bool.fromEnvironment('dart.library.js_interop') ||
      const bool.fromEnvironment('dart.library.io') ||
      const bool.fromEnvironment('dart.library.ffi') ||
      const bool.fromEnvironment('dart.library.html') ||
      const bool.fromEnvironment('dart.library.js') ||
      const String.fromEnvironment(
            'dart.library.io',
            defaultValue: 'missing',
          ) !=
          'missing' ||
      const String.fromEnvironment(
            'dart.library.ffi',
            defaultValue: 'missing',
          ) !=
          'missing' ||
      const String.fromEnvironment(
            'dart.library.html',
            defaultValue: 'missing',
          ) !=
          'missing' ||
      const String.fromEnvironment(
            'dart.library.js',
            defaultValue: 'missing',
          ) !=
          'missing') {
    throw StateError('Unexpected Dart Wasm conditional environment.');
  }
  return value;
}
