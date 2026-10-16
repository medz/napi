/// Requested boundary behavior for a selected Dart class.
///
/// These policies describe declarations, not available runtime engines.
enum ClassPolicy { reference, value, resource }

/// Selects a public function or class for a napi binding.
///
/// An annotated class includes its own public members, not inherited members.
/// On those members, [name] overrides the public name and [exclude] removes the
/// member from selection. They cannot be combined. Class runtime generation is
/// separate from declaration discovery.
///
/// On a top-level function, [bigint] selects JavaScript `bigint` for every Dart
/// `int` parameter and result, including nullable integers. Otherwise Dart `int`
/// uses JavaScript safe-integer `number` values. Dart `BigInt` always uses
/// JavaScript `bigint`; other scalar types are unaffected. The [bigint] option
/// is not supported on classes, class members, or excluded declarations.
class NAPI {
  final String? name;
  final bool exclude;
  final bool bigint;

  /// Class-only policy; omitted classes retain reference semantics.
  final ClassPolicy? classPolicy;

  /// Original Dart name of a resource's own public instance cleanup method.
  ///
  /// Required for [ClassPolicy.resource] and invalid for other policies. Its
  /// full signature is retained; resource invocation and lifecycle generation
  /// remain backend work. This does not add disposal to ordinary classes.
  final String? cleanup;

  /// Public Dart constructor name (`new` for unnamed) for value inputs.
  /// Omission makes a value class output-only.
  final String? valueConstructor;

  /// Constructor parameter to own field/getter overrides, using Dart names.
  /// Unlisted parameters match the same Dart member name exactly.
  final Map<String, String>? valueFields;

  const NAPI({
    this.name,
    this.exclude = false,
    this.bigint = false,
    this.classPolicy,
    this.cleanup,
    this.valueConstructor,
    this.valueFields,
  });
}
