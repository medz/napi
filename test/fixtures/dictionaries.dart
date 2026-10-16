import 'dart:collection';

import 'package:napi/napi.dart';

import 'classes.dart';
export 'maps.dart';

int _calls = 0;
Dictionary<RefBox?>? _held;

@NAPI()
int dictionaryCalls() => _calls;
@NAPI()
Dictionary<int> echoDictionary(Dictionary<int> value) {
  _calls++;
  return value;
}

@NAPI()
Dictionary<List<(int, {RefBox? owner})?>?> nestedDictionary(
  Dictionary<List<(int, {RefBox? owner})?>?> value,
) => value;
@NAPI()
Dictionary<RefBox?> referenceDictionary(Dictionary<RefBox?> value) => value;
@NAPI()
int holdDictionary(Dictionary<RefBox?>? value) {
  _held = value;
  return 0;
}

@NAPI()
Dictionary<RefBox?>? heldDictionary() => _held;
@NAPI(bigint: true)
Dictionary<(int, BigInt?)> bigintDictionary(Dictionary<(int, BigInt?)> value) =>
    value;
@NAPI()
Dictionary<int>? optionalDictionary([Dictionary<int>? value]) => value;
@NAPI()
Dictionary<int>? namedDictionary({required Dictionary<int>? value}) => value;
@NAPI()
Dictionary<Dictionary<int>> recursiveDictionary(
  Dictionary<Dictionary<int>> value,
) => value;
@NAPI()
(Dictionary<int>, Map<String, int>) dictionaryAndMap(
  Dictionary<int> dictionary,
  Map<String, int> map,
) => (dictionary, map);

@NAPI()
class DictionaryHolder {
  Dictionary<int> values;
  final Dictionary<int>? initial;
  DictionaryHolder(this.values, {this.initial});
  Dictionary<int> replace(Dictionary<int> value) => values = value;
  static Dictionary<int> echo(Dictionary<int> value) => value;
}

@NAPI(name: 'Dictionary')
class UserDictionary {
  UserDictionary(this.value);
  int value;
  UserDictionary self() => this;
}

@NAPI()
Dictionary<UserDictionary> userDictionary(Dictionary<UserDictionary> value) =>
    value;

@NAPI()
Dictionary<int> customDictionary(int length, int mode) =>
    Dictionary(_CustomDictionary(length, mode));

class _CustomDictionary extends MapBase<String, int> {
  final int reportedLength;
  final int mode;
  _CustomDictionary(this.reportedLength, this.mode);
  @override
  int get length => reportedLength;
  @override
  Iterable<MapEntry<String, int>> get entries sync* {
    if (mode == 1) throw StateError('Dictionary entries failed');
    yield const MapEntry('a', 1);
    if (mode == 2) yield const MapEntry('a', 2);
  }

  @override
  Iterable<String> get keys => const ['a'];
  @override
  int? operator [](Object? key) => key == 'a' ? 1 : null;
  @override
  void operator []=(String key, int value) =>
      throw UnsupportedError('readonly');
  @override
  void clear() => throw UnsupportedError('readonly');
  @override
  int? remove(Object? key) => throw UnsupportedError('readonly');
}

RefChild? _partial;
@NAPI()
Dictionary<(RefBase, int)> failingDictionaryReference() => Dictionary({
  'first': (_partial = RefChild(), 0),
  'bad': (_partial!, 9007199254740992),
});
@NAPI()
RefChild dictionaryReferenceChild() => _partial!;
@NAPI()
Dictionary<(RefBase, int)> failingExistingDictionaryReference(RefBase value) =>
    Dictionary({'first': (value, 0), 'bad': (value, 9007199254740992)});
