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

/// Creates the analyzer view for Wasm, or VM AOT when [native] is true.
/// Both mappings retain target-specific conditional imports and core identity.
///
/// Analyzer's normal SDK map covers several targets and can substitute
/// `dart2jsPath` entries. Its public context factory also cannot configure
/// conditional imports. Keep both version-specific adaptations here: expose
/// the `wasm` target's unpatched source libraries through an in-memory metadata
/// overlay and give the resolver the same library environment as dart2wasm.
/// In particular, retain the real `dart:core` int and double declarations.
AnalysisContextCollection createSdkAnalysisContext({
  required String path,
  String? sdkPath,
  String? packageConfigFile,
  bool native = false,
}) {
  final target = native ? 'vm' : 'wasm';
  final sdk = p.normalize(p.absolute(sdkPath ?? getSdkPath()));
  final libraries = _readLibraries(sdk, target);
  final metadata = StringBuffer('const libraries = {\n');
  final variables = <String, String>{};
  for (final entry in libraries.entries) {
    final name = entry.key;
    final info = entry.value;
    metadata.writeln(
      '  ${jsonEncode(name)}: const LibraryInfo(${jsonEncode(info.uri)}),',
    );
    // dart2wasm 3.13.5 disables FFI's environment declaration, even
    // though the shared libraries.json target contains its stub sources.
    // AOT disables mirrors even though VM metadata includes its library.
    // Unsupported names must be absent, not defined as the string "false".
    if (info.conditional &&
        !name.startsWith('_') &&
        (native ? name != 'mirrors' : name != 'ffi')) {
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
      throw SdkCompatibilityException(
        'NAPI_SDK_LAYOUT',
        'Analyzer did not select the configured $target SDK libraries.',
      );
    }
  }
  return collection;
}

typedef _SdkLibrary = ({String uri, bool conditional});

Map<String, _SdkLibrary> _readLibraries(String sdk, String selectedTarget) {
  Never invalid(String message) => throw SdkCompatibilityException(
    'NAPI_SDK_LAYOUT',
    'Cannot configure Dart $supportedDartSdkVersion $selectedTarget analysis: $message',
  );

  try {
    final version = File(p.join(sdk, 'version')).readAsStringSync().trim();
    if (version != supportedDartSdkVersion) {
      throw SdkCompatibilityException(
        'NAPI_SDK_VERSION',
        '$selectedTarget analysis requires Dart $supportedDartSdkVersion. Found: $version',
      );
    }
    final specification = jsonDecode(
      File(p.join(sdk, 'lib', 'libraries.json')).readAsStringSync(),
    );
    if (specification is! Map<String, dynamic>) {
      invalid('libraries.json is not an object.');
    }
    final visiting = <String>{};
    Map<String, _SdkLibrary> resolve(String target) {
      if (!visiting.add(target)) invalid('Cyclic SDK target: $target.');
      final definition = specification[target];
      if (definition is! Map<String, dynamic>) {
        invalid('Missing SDK target: $target.');
      }
      final result = <String, _SdkLibrary>{};
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
        // The distributed stable SDK omits this VM-private service source;
        // it is absent from its analyzer metadata too. Keep other missing
        // sources fatal rather than silently hiding public libraries.
        if (selectedTarget == 'vm' && entry.key == '_vmservice') continue;
        if (!File(p.join(sdk, 'lib', p.fromUri(uri))).existsSync()) {
          invalid('Missing source for dart:${entry.key}.');
        }
        result[entry.key] = (uri: uri, conditional: conditional);
      }
      visiting.remove(target);
      return result;
    }

    final libraries = resolve(selectedTarget);
    if (libraries['core']?.uri != 'core/core.dart') {
      invalid(
        'The $selectedTarget target must use the real dart:core declarations.',
      );
    }
    return libraries;
  } on FileSystemException catch (error) {
    invalid(error.message);
  } on FormatException catch (error) {
    invalid(error.message);
  }
}
