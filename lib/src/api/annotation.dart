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
  const NAPI({this.name, this.exclude = false, this.bigint = false});
}
