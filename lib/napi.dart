/// Declare Dart APIs to export to JavaScript.
library;

import 'package:meta/meta_meta.dart';

export 'js_types.dart';

/// Exports a Dart declaration using its name, or [name] when supplied.
@Target({
  TargetKind.type,
  TargetKind.function,
  TargetKind.method,
  TargetKind.getter,
  TargetKind.setter,
  TargetKind.constructor,
  TargetKind.field,
  TargetKind.topLevelVariable,
})
final class NAPI {
  const NAPI({this.name});

  final String? name;
}
