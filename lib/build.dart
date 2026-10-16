/// Build-time API for selected Dart libraries.
///
/// Source annotations use `package:napi/napi.dart`. External selections leave
/// the target library unchanged. This entrypoint belongs in the separate build
/// script running on the Dart VM.
library;

import 'dart:io';

import 'src/build/build.dart' as builder;
import 'src/compiler/front_end/external.dart';

export 'src/build/build.dart' show BuiltModule;
export 'src/build/package.dart' show assembleWasmPackage;
export 'src/api/annotation.dart' show NAPI, ClassPolicy;
export 'src/compiler/analysis/validate.dart' show BindingDiagnostic;
export 'src/compiler/front_end/external.dart';
export 'src/compiler/ir/model.dart' show SourceLocation;

/// Build a library's selected declarations into a fresh output directory.
///
/// Unsupported declarations raise [BindingDiagnostic] before output or staging
/// is created. Existing output is never replaced. [packagesPath] selects the
/// package configuration shared by source analysis and compilation.
/// [external] selects declarations without changing their library or copying
/// signatures. With external selections, [library] can also be a package URI.
Future<builder.BuiltModule> buildLibrary({
  required Uri library,
  required Directory output,
  String? packagesPath,
  ExternalLibrary? external,
}) => builder.buildLibrary(
  library: library,
  output: output,
  packagesPath: packagesPath,
  external: external,
);
