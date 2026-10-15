/// Selects a public function or class for a napi binding.
///
/// An annotated class includes its own public members, not inherited members.
/// On those members, [name] overrides the public name and [exclude] removes the
/// member from selection. They cannot be combined. Class runtime generation is
/// separate from declaration discovery.
class NAPI {
  final String? name;
  final bool exclude;
  const NAPI({this.name, this.exclude = false});
}
