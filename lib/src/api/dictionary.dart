/// A string-keyed object at the JavaScript boundary.
///
/// Dart code uses the underlying Map directly. Bindings copy its values to and
/// from plain JavaScript objects; generated outputs have a null prototype.
extension type const Dictionary<V>(Map<String, V> _)
    implements Map<String, V> {}
