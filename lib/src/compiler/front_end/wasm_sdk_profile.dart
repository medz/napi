import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
// The public collection constructor cannot supply declared variables. Keep this
// analyzer-version-bounded implementation detail inside the frontend adapter.
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';

import '../ir/binding.dart';
import '../ir/diagnostic.dart';

/// Conditional-library profile of `dart compile wasm` with its default flags.
///
/// Read the same SDK used by the build runner, never the VM analysis defaults.
/// Unavailable libraries are undefined, rather than defined with value false:
/// conditional imports can explicitly compare a variable to the string false.
final class WasmSdkProfile {
  WasmSdkProfile._(this.sdkPath, Map<String, String> variables)
    : declaredVariables = Map.unmodifiable(variables);

  final String sdkPath;
  final Map<String, String> declaredVariables;

  static WasmSdkProfile load({required Uri sourceUri, String? sdkPath}) {
    try {
      final root =
          sdkPath ??
          File(Platform.resolvedExecutable).resolveSymbolicLinksSync();
      final sdk = sdkPath == null ? File(root).parent.parent.path : root;
      final manifest = jsonDecode(
        File('$sdk/lib/libraries.json').readAsStringSync(),
      );
      if (manifest is! Map<String, dynamic>) {
        throw const FormatException(
          'SDK libraries manifest must be an object.',
        );
      }
      final libraries = <String, Map<String, dynamic>>{};
      final visiting = <String>{};
      void include(String name) {
        if (!visiting.add(name)) {
          throw FormatException('Cyclic SDK target include: $name.');
        }
        final target = manifest[name];
        if (target is! Map<String, dynamic>) {
          throw FormatException('Missing SDK target $name.');
        }
        final includes = target['include'] ?? const [];
        if (includes is! List) {
          throw const FormatException('Invalid SDK target includes.');
        }
        for (final entry in includes) {
          if (entry is! Map<String, dynamic> ||
              entry['target'] is! String ||
              entry.containsKey('path')) {
            throw const FormatException('Unsupported SDK target include.');
          }
          include(entry['target'] as String);
        }
        final own = target['libraries'];
        if (own is! Map<String, dynamic>) {
          throw FormatException('Missing libraries for SDK target $name.');
        }
        for (final entry in own.entries) {
          final value = entry.value;
          if (value is! Map<String, dynamic> || value['uri'] is! String) {
            throw FormatException('Invalid SDK library ${entry.key}.');
          }
          for (final flag in ['supported', 'support_conditional_import']) {
            if (value.containsKey(flag) && value[flag] is! bool) {
              throw FormatException(
                'Invalid $flag for SDK library ${entry.key}.',
              );
            }
          }
          libraries[entry.key] = value;
        }
        visiting.remove(name);
      }

      include('wasm');
      final variables = <String, String>{};
      for (final entry in libraries.entries) {
        if (entry.value['supported'] != false &&
            entry.value['support_conditional_import'] != false &&
            entry.key != 'ffi' &&
            !entry.key.startsWith('_')) {
          // dart2wasm excludes private names and only enables ffi with its
          // non-default experimental flag.
          variables['dart.library.${entry.key}'] = 'true';
        }
      }
      if (variables['dart.library.js_interop'] != 'true' ||
          variables['dart.library.core'] != 'true') {
        throw const FormatException(
          'SDK does not declare the supported Wasm JS profile.',
        );
      }
      return WasmSdkProfile._(sdk, variables);
    } on FileSystemException catch (error) {
      throw _diagnostic(sourceUri, error.message);
    } on FormatException catch (error) {
      throw _diagnostic(sourceUri, error.message);
    }
  }

  AnalysisContextCollection createContext(String sourcePath) =>
      AnalysisContextCollectionImpl(
        includedPaths: [sourcePath],
        sdkPath: sdkPath,
        declaredVariables: declaredVariables,
      );

  static BindingCompilationException _diagnostic(
    Uri sourceUri,
    String detail,
  ) => BindingCompilationException([
    BindingDiagnostic(
      code: 'sdk_profile',
      message: 'Cannot establish the compiling SDK Wasm profile: $detail',
      source: SourceSpan(
        uri: sourceUri,
        offset: 0,
        length: 0,
        line: 1,
        column: 1,
      ),
    ),
  ]);
}
