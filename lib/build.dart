/// Build-time API for annotated Dart libraries.
///
/// Import `package:napi/napi.dart` in the library being compiled; this entrypoint
/// belongs in the separate build script running on the Dart VM.
library;

import 'dart:io';

import 'src/build/build.dart' as builder;

export 'src/build/build.dart' show BuiltModule;
export 'src/compiler/analysis/validate.dart' show BindingDiagnostic;
export 'src/compiler/ir/model.dart' show SourceLocation;

/// Build a library's selected declarations into a fresh output directory.
///
/// Unsupported declarations raise [BindingDiagnostic] before output or staging
/// is created. Existing output is never replaced. [packagesPath] selects the
/// package configuration shared by source analysis and compilation.
Future<builder.BuiltModule> buildLibrary({
  required Uri library,
  required Directory output,
  String? packagesPath,
}) => builder.buildLibrary(
  library: library,
  output: output,
  packagesPath: packagesPath,
);
