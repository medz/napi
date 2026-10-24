import 'dart:convert';

import 'dart_sdk_adapter.dart';

/// Extracts compiler-owned helpers and captures DataView intrinsics.
///
/// This textual dependency is private, version pinned, and checked before any
/// linked output is published. Deferred loading and unknown loader layouts are
/// deliberately unsupported. Native ESM supplies the instance and JS string
/// builtins, so compile/instantiate/invokeMain are never copied into the host.
String extractDartHostHelpers(String source) {
  const instance =
      '  async instantiate(additionalImports, '
      '{loadDeferredModules, loadDeferredId} = {}) {\n'
      '    let dartInstance;\n\n';
  const helpers = '    // Prints to the console\n';
  const imports = '    const dart2wasm = {\n';
  const base = '    const baseImports = {\n';
  const polyfill = '    const jsStringPolyfill = {\n';
  const instantiate =
      '    dartInstance = await WebAssembly.instantiate(this.module, {\n'
      '      ...baseImports,\n'
      '      ...additionalImports,\n'
      '      \n'
      '      "wasm:js-string": jsStringPolyfill,\n'
      '    });\n\n'
      '    return new InstantiatedApp(this, dartInstance);';
  int unique(String marker) {
    final index = source.indexOf(marker);
    if (index < 0 || source.indexOf(marker, index + 1) >= 0) _layoutError();
    return index;
  }

  final instanceIndex = unique(instance);
  final start = unique(helpers);
  final importsIndex = unique(imports);
  final baseIndex = unique(base);
  final polyfillIndex = unique(polyfill);
  final instantiateIndex = unique(instantiate);
  extractDartStringConstants(source);
  if (instanceIndex + instance.length != start ||
      importsIndex <= start ||
      baseIndex <= importsIndex ||
      polyfillIndex <= baseIndex ||
      instantiateIndex <= polyfillIndex ||
      !source.substring(start, baseIndex).endsWith('    };\n\n') ||
      !RegExp(r'    };\s*$')
          .hasMatch(source.substring(polyfillIndex, instantiateIndex)) ||
      RegExp(r"const builtins = \{builtins: \['js-string'\]\};")
              .allMatches(source)
              .length !=
          2) {
    _layoutError();
  }
  return _captureDataViewHelpers(source.substring(start, baseIndex));
}

// ByteData.view in the pinned SDK otherwise reads replaceable DataView getters
// and constructors on each copy. Match only these SDK expressions, not arbitrary
// user interop. Helpers can be absent after tree shaking.
String _captureDataViewHelpers(String helpers) {
  const replacements = {
    'o => o.buffer': "Function.prototype.call.bind(Object.getOwnPropertyDescriptor(DataView.prototype, 'buffer').get)",
    'o => o.byteOffset': "Function.prototype.call.bind(Object.getOwnPropertyDescriptor(DataView.prototype, 'byteOffset').get)",
    '(b, o) => new DataView(b, o)': r'(b, o) => new $napiDataView(b, o)',
    '(b, o, l) => new DataView(b, o, l)':
        r'(b, o, l) => new $napiDataView(b, o, l)',
  };
  final candidate = RegExp(
    r'^(?:\(?o\)?\s*=>\s*o\.(?:buffer|byteOffset)\b|'
    r'\(b,\s*o(?:,\s*l)?\)\s*=>\s*new\s+DataView\b)',
  );
  var captureConstructor = false;
  final result = helpers.replaceAllMapped(
    RegExp(r'^( {6,12}[A-Za-z_$][A-Za-z0-9_$]*: )([^\n]*)$', multiLine: true),
    (match) {
      final expression = match[2]!;
      if (!candidate.hasMatch(expression)) return match[0]!;
      final replacement = expression.endsWith(',')
          ? replacements[expression.substring(0, expression.length - 1)]
          : null;
      if (replacement == null) _layoutError();
      if (expression.startsWith('(b,')) captureConstructor = true;
      return '${match[1]}$replacement,';
    },
  );
  return captureConstructor
      ? '    const \$napiDataView = DataView;\n$result'
      : result;
}

/// The pinned compiler uses indexed strings when UTF-16 cannot fit a UTF-8
/// Wasm import name. Accept only its exact table layout and JSON string values;
/// never evaluate JavaScript from the loader.
List<String> extractDartStringConstants(String source) {
  const base = '    const baseImports = {\n';
  const polyfill = '    const jsStringPolyfill = {\n';
  final start = source.indexOf(base);
  final end = source.indexOf(polyfill);
  if (start < 0 ||
      end <= start ||
      source.indexOf(base, start + 1) >= 0 ||
      source.indexOf(polyfill, end + 1) >= 0) {
    _layoutError();
  }
  var body = source.substring(start, end);
  final strings = <String>[];
  const table = '      s: [\n';
  const close = '      ],\n';
  final tableStart = body.indexOf(table);
  if (tableStart >= 0) {
    final tableEnd = body.indexOf(close, tableStart + table.length);
    if (tableEnd < 0 || body.indexOf(table, tableStart + 1) >= 0) {
      _layoutError();
    }
    if (!body
        .substring(tableEnd + close.length)
        .startsWith(
          '      "": new Proxy({}, { get(_, prop) { return prop; } }),\n',
        )) {
      _layoutError();
    }
    final rows = body.substring(tableStart + table.length, tableEnd);
    if (rows.isEmpty || !rows.endsWith('\n')) _layoutError();
    for (final row in rows.substring(0, rows.length - 1).split('\n')) {
      if (!row.startsWith('        "') || !row.endsWith('",')) {
        _layoutError();
      }
      Object? value;
      try {
        value = jsonDecode(row.substring(8, row.length - 1));
      } on FormatException {
        _layoutError();
      }
      if (value is! String) _layoutError();
      strings.add(value);
    }
    body = body.replaceRange(tableStart, tableEnd + close.length, '');
  }
  const expected = '''    const baseImports = {
      dart2wasm: dart2wasm,
      Math: Math,
      Date: Date,
      Object: Object,
      Array: Array,
      Reflect: Reflect,
      WebAssembly: {
        JSTag: WebAssembly.JSTag,
      },
      "": new Proxy({}, { get(_, prop) { return prop; } }),

    };

''';
  if (body != expected) _layoutError();
  return List.unmodifiable(strings);
}

/// The compiler currently emits an identifier-keyed object of host functions.
/// Validate every linked helper before writing output, rather than discovering
/// an SDK layout mismatch when the consumer imports the finished package.
void verifyDartHostImport(String helpers, String name) {
  if (!RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(name) ||
      !RegExp(
        '^ {6,12}${RegExp.escape(name)}: ',
        multiLine: true,
      ).hasMatch(helpers)) {
    throw SdkCompatibilityException(
      'NAPI_SDK_HOST_IMPORT',
      'Dart 3.13.5 host helper "$name" is missing or has an unknown layout.',
    );
  }
}

Never _layoutError() => throw const SdkCompatibilityException(
  'NAPI_SDK_HOST_LAYOUT',
  'Unrecognized Dart 3.13.5 host-module layout. Refusing to link. '
      'Use the pinned SDK without deferred loading or custom compiler options.',
);
