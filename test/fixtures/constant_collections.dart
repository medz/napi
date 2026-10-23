import 'dart:collection';

final class ConstList<E> with ListMixin<E> {
  const ConstList(this.storage);
  final List<E> storage;

  @override
  int get length => storage.length;
  @override
  set length(int value) => throw UnsupportedError('const list');
  @override
  E operator [](int index) => storage[index];
  @override
  void operator []=(int index, E value) => throw UnsupportedError('const list');
}

final class ConstMap<K, V> with MapMixin<K, V> {
  const ConstMap(this.storage);
  final Map<K, V> storage;

  @override
  V? operator [](Object? key) => storage[key];
  @override
  Iterable<K> get keys => storage.keys;
  @override
  void operator []=(K key, V value) => throw UnsupportedError('const map');
  @override
  void clear() => throw UnsupportedError('const map');
  @override
  V? remove(Object? key) => throw UnsupportedError('const map');
}
