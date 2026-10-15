import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/file_system/overlay_file_system.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
// These adapters are deliberately pinned by the exact analyzer dependency.
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
// ignore: implementation_imports
import 'package:analyzer/src/util/sdk.dart';
import 'package:path/path.dart' as p;

import '../sdk_adapter/dart_sdk_adapter.dart';

/// Creates the analyzer view of the SDK used by [DartSdkAdapter].
///
/// Analyzer's normal SDK map covers several targets and can substitute
/// `dart2jsPath` entries. Its public context factory also cannot configure
/// conditional imports. Keep both version-specific adaptations here: expose
/// the `wasm` target's unpatched source libraries through an in-memory metadata
/// overlay and give the resolver the same library environment as dart2wasm.
/// In particular, retain the real `dart:core` int and double declarations.
AnalysisContextCollection createWasmAnalysisContext({
  required String path,
  String? sdkPath,
  String? packageConfigFile,
}) {
  final sdk = p.normalize(p.absolute(sdkPath ?? getSdkPath()));
  final libraries = _readWasmLibraries(sdk);
  final metadata = StringBuffer('const libraries = {\n');
  final variables = <String, String>{};
  for (final entry in libraries.entries) {
    final name = entry.key;
    final info = entry.value;
    metadata.writeln(
      '  ${jsonEncode(name)}: const LibraryInfo(${jsonEncode(info.uri)}),',
    );
    // dart2wasm 3.13.5 also disables FFI's environment declaration, even
    // though the shared libraries.json target contains its stub sources.
    // Unsupported names must be absent, not defined as the string "false".
    if (info.conditional && !name.startsWith('_') && name != 'ffi') {
      variables['dart.library.$name'] = 'true';
    }
  }
  metadata.writeln('};');

  final resources = OverlayResourceProvider(PhysicalResourceProvider.INSTANCE);
  resources.setOverlay(
    p.join(
      sdk,
      'lib',
      '_internal',
      'sdk_library_metadata',
      'lib',
      'libraries.dart',
    ),
    content: metadata.toString(),
    modificationStamp: 0,
  );
  final collection = AnalysisContextCollectionImpl(
    includedPaths: [p.normalize(p.absolute(path))],
    sdkPath: sdk,
    packageConfigFile: packageConfigFile == null
        ? null
        : p.normalize(p.absolute(packageConfigFile)),
    resourceProvider: resources,
    declaredVariables: variables,
  );
  // Analyzer can replace the requested SDK with a package's embedder SDK.
  // Verify the effective mapping rather than accepting a different platform.
  for (final context in collection.contexts) {
    final effectiveSdk = context.driver.sourceFactory.dartSdk;
    if (effectiveSdk == null ||
        effectiveSdk.uris.length != libraries.length ||
        libraries.entries.any(
          (entry) =>
              effectiveSdk.mapDartUri('dart:${entry.key}')?.fullName !=
              p.join(sdk, 'lib', p.fromUri(entry.value.uri)),
        )) {
      unawaited(collection.dispose());
      throw const SdkCompatibilityException(
        'NAPI_SDK_LAYOUT',
        'Analyzer did not select the configured Wasm SDK libraries.',
      );
    }
  }
  return collection;
}

typedef _WasmLibrary = ({String uri, bool conditional});

Map<String, _WasmLibrary> _readWasmLibraries(String sdk) {
  Never invalid(String message) => throw SdkCompatibilityException(
    'NAPI_SDK_LAYOUT',
    'Cannot configure Dart $supportedDartSdkVersion Wasm analysis: $message',
  );

  try {
    final version = File(p.join(sdk, 'version')).readAsStringSync().trim();
    if (version != supportedDartSdkVersion) {
      throw SdkCompatibilityException(
        'NAPI_SDK_VERSION',
        'Wasm analysis requires Dart $supportedDartSdkVersion. Found: $version',
      );
    }
    final specification = jsonDecode(
      File(p.join(sdk, 'lib', 'libraries.json')).readAsStringSync(),
    );
    if (specification is! Map<String, dynamic>) {
      invalid('libraries.json is not an object.');
    }
    final visiting = <String>{};
    Map<String, _WasmLibrary> resolve(String target) {
      if (!visiting.add(target)) invalid('Cyclic SDK target: $target.');
      final definition = specification[target];
      if (definition is! Map<String, dynamic>) {
        invalid('Missing SDK target: $target.');
      }
      final result = <String, _WasmLibrary>{};
      final includes = definition['include'] ?? const [];
      if (includes is! List) invalid('Invalid includes for $target.');
      for (final include in includes) {
        // This pinned SDK only uses local target includes. Reject unfamiliar
        // layouts instead of silently choosing another platform.
        if (include is! Map<String, dynamic> ||
            include['target'] is! String ||
            include.containsKey('path')) {
          invalid('Unsupported include in $target.');
        }
        result.addAll(resolve(include['target'] as String));
      }
      final entries = definition['libraries'];
      if (entries is! Map<String, dynamic>) {
        invalid('Missing libraries for $target.');
      }
      for (final entry in entries.entries) {
        final data = entry.value;
        if (data is! Map<String, dynamic>) {
          invalid('Invalid dart:${entry.key} metadata.');
        }
        final uri = data['uri'];
        final conditional = data['support_conditional_import'] ?? true;
        final direct = data['support_direct_import'] ?? 'always';
        if (!RegExp(r'^[a-zA-Z_][a-zA-Z_0-9]*$').hasMatch(entry.key) ||
            uri is! String ||
            !RegExp(r'^[a-zA-Z_0-9./-]+$').hasMatch(uri) ||
            p.posix.isAbsolute(uri) ||
            uri.split('/').contains('..') ||
            conditional is! bool ||
            direct != 'always') {
          invalid('Unsupported dart:${entry.key} metadata.');
        }
        if (!File(p.join(sdk, 'lib', p.fromUri(uri))).existsSync()) {
          invalid('Missing source for dart:${entry.key}.');
        }
        result[entry.key] = (uri: uri, conditional: conditional);
      }
      visiting.remove(target);
      return result;
    }

    final libraries = resolve('wasm');
    if (libraries['core']?.uri != 'core/core.dart') {
      invalid('The Wasm target must use the real dart:core declarations.');
    }
    return libraries;
  } on FileSystemException catch (error) {
    invalid(error.message);
  } on FormatException catch (error) {
    invalid(error.message);
  }
}
