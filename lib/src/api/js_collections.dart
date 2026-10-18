/// A retained handle to an existing JavaScript Array.
///
/// Reads and writes use the original object. Ordinary Dart Lists remain copied
/// bindings. Only scalar element types are currently supported.
abstract interface class JsArray<T> {
  int get length;

  /// Returns null beyond the current length. Within the Array, ordinary property
  /// lookup includes inherited values and getters; an undefined result fails
  /// the declared element conversion.
  T? get(int index);

  /// Uses JavaScript property assignment, including setters and extension.
  void set(int index, T value);
}

/// A retained handle to an existing JavaScript Map, using SameValueZero keys.
///
/// Only scalar key and value types are currently supported. Returning a handle
/// to JavaScript preserves the original Map identity.
abstract interface class JsMap<K, V> {
  int get size;
  bool has(K key);

  /// Returns null for an absent key. Use [has] to distinguish a stored null.
  V? get(K key);
  void set(K key, V value);
  bool delete(K key);
  void clear();

  /// Iterates the original Map in insertion order, with native Map mutation
  /// behavior. Each step validates its key and value at the time of reading.
  Iterable<(K, V)> get entries;
}
