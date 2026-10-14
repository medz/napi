import 'dart_sdk_adapter.dart';

/// Extracts compiler-owned helpers, without changing their implementation.
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
  const expectedBase = '''    const baseImports = {
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
  if (instanceIndex + instance.length != start ||
      importsIndex <= start ||
      baseIndex <= importsIndex ||
      polyfillIndex <= baseIndex ||
      instantiateIndex <= polyfillIndex ||
      source.substring(baseIndex, polyfillIndex) != expectedBase ||
      !source.substring(start, baseIndex).endsWith('    };\n\n') ||
      !RegExp(r'    };\s*$')
          .hasMatch(source.substring(polyfillIndex, instantiateIndex)) ||
      RegExp(r"const builtins = \{builtins: \['js-string'\]\};")
              .allMatches(source)
              .length !=
          2) {
    _layoutError();
  }
  return source.substring(start, baseIndex);
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
