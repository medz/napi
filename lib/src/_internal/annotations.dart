import 'package:meta/meta.dart';
import 'package:meta/meta_meta.dart';

/// Availability metadata for an individual API declaration.
///
/// There are no library-level defaults. Without a Node.js constraint, a stable
/// API is available wherever its Node-API version is supported.
@internal
@Target({
  TargetKind.type,
  TargetKind.enumValue,
  TargetKind.function,
  TargetKind.method,
  TargetKind.getter,
  TargetKind.setter,
  TargetKind.constructor,
  TargetKind.field,
  TargetKind.topLevelVariable,
})
final class Available {
  const Available({this.napi, this.node});

  /// The required Node-API version.
  final int? napi;

  /// Additional Node.js version constraints; `||` separates alternatives.
  final String? node;
}
