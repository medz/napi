/// Requested boundary behavior for a selected Dart class.
///
/// These policies describe declarations, not available runtime engines.
enum ClassPolicy { reference, value, resource }

/// Selects a public function, concrete callable const or class for a napi binding.
///
/// An annotated class includes its own public members, not inherited members.
/// On those members, [name] overrides the public name and [exclude] removes the
/// member from selection. They cannot be combined. Class runtime generation is
/// separate from declaration discovery.
///
/// A top-level const such as `const readInt = read<int>` selects an explicit
/// specialization of a top-level function or static method. Its Dart type and
/// defaults become the exported callable signature.
///
/// On a top-level function or concrete callable const, [bigint] selects JavaScript
/// `bigint` for every Dart
/// `int` parameter and result, including nullable integers. Otherwise Dart `int`
/// uses JavaScript safe-integer `number` values. Dart `BigInt` always uses
/// JavaScript `bigint`; other scalar types are unaffected. The [bigint] option
/// is not supported on classes, class members, or excluded declarations.
/// Generic parameters are read from the Dart declaration. Supported parameters
/// carry unchanged JavaScript payloads; arbitrary Dart runtime specialization
/// is not implied by a TypeScript type argument.
class NAPI {
  final String? name;
  final bool exclude;
  final bool bigint;

  /// Class-only policy; omitted classes retain reference semantics.
  final ClassPolicy? classPolicy;

  /// Original Dart name of a resource's own public instance cleanup method.
  ///
  /// Required for [ClassPolicy.resource] and invalid for other policies. Its
  /// full signature is retained. Generated cleanup exposes `Promise<void>` for
  /// a selected `void` or `Future<void>` method and waits for accepted operation
  /// leases. This does not add disposal to ordinary classes.
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
