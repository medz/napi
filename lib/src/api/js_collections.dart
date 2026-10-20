/// A retained handle to an existing JavaScript Array.
///
/// Reads and writes use the original object. Ordinary Dart Lists remain copied
/// bindings. Elements support scalars, nested JS collection handles and direct
/// opaque type parameters, including nullable forms. Opaque values follow the
/// storage-only contract.
abstract interface class JsArray<T> {
  int get length;

  /// Returns null beyond the current length. Within the Array, ordinary property
  /// lookup includes inherited values and getters. Undefined fails scalar or
  /// handle conversion, but is a value for an opaque element. Present opaque
  /// null and undefined have non-null Dart carriers, distinct from absence.
  T? get(int index);

  /// Uses JavaScript property assignment, including setters and extension.
  void set(int index, T value);
}

/// A retained handle to an existing JavaScript Map, using SameValueZero keys.
///
/// Keys and values support scalars, nested JS collection handles and direct
/// opaque type parameters, including nullable forms. Returning a handle preserves
/// the original Map identity.
abstract interface class JsMap<K, V> {
  int get size;
  bool has(K key);

  /// Returns null for an absent key. Use [has] to distinguish a stored scalar
  /// null. Present opaque null and undefined have non-null Dart carriers.
  V? get(K key);
  void set(K key, V value);
  bool delete(K key);
  void clear();

  /// Iterates the original Map in insertion order, with native Map mutation
  /// behavior. Each step validates its key and value at the time of reading.
  Iterable<(K, V)> get entries;
}
