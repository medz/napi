import 'dart:collection';
import 'dart:typed_data';

import 'package:napi/napi.dart';

import 'records_models.dart' as models;

typedef MapOnly = ({String label, double score});

@napi
Map<String, models.User> echoUsers(Map<String, models.User> users) => users;

@napi
Future<Map<String, models.User>> echoUsersAsync(
  Map<String, models.User> users,
) async {
  await Future<void>.delayed(const Duration(milliseconds: 1));
  return users;
}

@napi
Map<String, models.User> normalizeUsers(Map<String, models.User> users) => {
  for (final entry in users.entries)
    entry.key: (
      name: entry.value.name.trim(),
      age: entry.value.age < 0 ? 0 : entry.value.age,
      active: entry.value.active ?? false,
    ),
};

@napi
Map<String, models.User?> echoNullableUsers(Map<String, models.User?> users) =>
    users;

@napi
Future<Map<String, models.User?>> echoNullableUsersAsync(
  Map<String, models.User?> users,
) async => users;

@napi
Map<String, models.User>? echoNullableContainer(
  Map<String, models.User>? users,
) => users;

@napi
Future<Map<String, models.User>?> echoNullableContainerAsync(
  Map<String, models.User>? users,
) async => users;

@napi
Map<String, models.User?>? echoNullableBoth(Map<String, models.User?>? users) =>
    users;

@napi
Future<Map<String, models.User?>?> echoNullableBothAsync(
  Map<String, models.User?>? users,
) async => users;

@napi
Map<String, models.MaybeUserAlias> echoAlias(
  Map<String, models.MaybeUserAlias> users,
) => users;

@napi
Future<Map<String, models.MaybeUserAlias>> echoAliasAsync(
  Map<String, models.MaybeUserAlias> users,
) async => users;

@napi
Map<String, ({String label, int count, bool? flag, double score})?>? echoInline(
  Map<String, ({String label, int count, bool? flag, double score})?>? values,
) => values;

@napi
Future<Map<String, ({String label, int count, bool? flag, double score})?>?>
echoInlineAsync(
  Map<String, ({String label, int count, bool? flag, double score})?>? values,
) async => values;

@napi
Map<String, MapOnly> echoMapOnly(Map<String, MapOnly> values) => values;

@napi
Map<String, models.Mixed> echoMixed(Map<String, models.Mixed> values) => values;

@napi
Map<String, models.SpecialFields> echoSpecial(
  Map<String, models.SpecialFields> values,
) => values;

@napi
Map<String, models.Packet> echoPackets(Map<String, models.Packet> values) =>
    values;

@napi
Future<Map<String, models.Packet>> echoPacketsAsync(
  Map<String, models.Packet> values,
) async {
  await Future<void>.delayed(const Duration(milliseconds: 1));
  return values;
}

@napi
Map<String, models.MaybePacket>? echoNullablePackets(
  Map<String, models.MaybePacket>? values,
) => values;

@napi
Future<Map<String, models.MaybePacket>?> echoNullablePacketsAsync(
  Map<String, models.MaybePacket>? values,
) async => values;

@napi
Map<String, ({String name, Uint8List? payload})?>? echoInlinePackets(
  Map<String, ({String name, Uint8List? payload})?>? values,
) => values;

@napi
Map<String, models.ByteFields> echoByteFields(
  Map<String, models.ByteFields> values,
) => values;

@napi
Map<String, models.Packet> normalizePackets(Map<String, models.Packet> values) {
  for (final entry in values.entries) {
    for (var index = 0; index < entry.value.payload.length; index++) {
      entry.value.payload[index] ^= 0xff;
    }
  }
  return values;
}

@napi
Future<Map<String, models.Packet>> normalizePacketsAsync(
  Map<String, models.Packet> values,
) async {
  await Future<void>.delayed(const Duration(milliseconds: 1));
  return normalizePackets(values);
}

var _calls = 0;
Map<String, models.Packet> _stored = {};

@napi
int calls() => _calls;

@napi
Map<String, models.Packet> trackedPackets(
  Map<String, models.Packet> first,
  Map<String, models.Packet> second,
) {
  _calls++;
  _stored = first;
  return second;
}

@napi
Future<Map<String, models.Packet>> trackedPacketsAsync(
  Map<String, models.Packet> first,
  Map<String, models.Packet> second,
) async {
  final result = trackedPackets(first, second);
  await Future<void>.delayed(const Duration(milliseconds: 1));
  return result;
}

@napi
Map<String, models.Packet> readPackets() => _stored;

@napi
void changePackets() {
  final packet = _stored.values.first;
  if (packet.payload.isNotEmpty) packet.payload[0] ^= 0xff;
  _stored['repeat'] = packet;
}

// Exercise failures while serializing a returned map after one valid entry.
// MapEntry is final: CastMap performs key/value casts while reading current,
// before an entry with a trustworthy key becomes available to the bridge.
@napi
Map<String, models.User> badUsers(int mode) => switch (mode) {
  4 => _LookupFailure(),
  5 => <String, Object>{
    'first': _user,
    'bad': 'wrong record',
  }.cast<String, models.User>(),
  6 => <Object, models.User>{
    'first': _user,
    7: _user,
  }.cast<String, models.User>(),
  7 => {
    'first': _user,
    'bad': (name: 'unsafe', age: 9007199254740992, active: null),
  },
  _ => _EntryFailure(mode),
};

@napi
Future<Map<String, models.User>> badUsersAsync(int mode) async =>
    badUsers(mode);

const models.User _user = (name: 'valid', age: 1, active: null);

final class _EntryFailure extends MapBase<String, models.User> {
  _EntryFailure(this.mode);
  final int mode;

  @override
  Iterable<MapEntry<String, models.User>> get entries {
    if (mode == 0) throw RangeError('entries failure');
    return _Entries(mode);
  }

  @override
  Iterable<String> get keys => const ['first', 'bad'];
  @override
  models.User? operator [](Object? key) => _user;
  @override
  void operator []=(String key, models.User value) =>
      throw UnimplementedError();
  @override
  models.User? remove(Object? key) => throw UnimplementedError();
  @override
  void clear() => throw UnimplementedError();
}

final class _LookupFailure extends MapBase<String, models.User> {
  @override
  Iterable<String> get keys => const ['first', 'bad'];
  @override
  models.User? operator [](Object? key) {
    if (key == 'bad') throw RangeError('lookup failure');
    return _user;
  }

  @override
  void operator []=(String key, models.User value) =>
      throw UnimplementedError();
  @override
  models.User? remove(Object? key) => throw UnimplementedError();
  @override
  void clear() => throw UnimplementedError();
}

final class _Entries extends IterableBase<MapEntry<String, models.User>> {
  _Entries(this.mode);
  final int mode;

  @override
  Iterator<MapEntry<String, models.User>> get iterator {
    if (mode == 1) throw RangeError('iterator failure');
    return _EntriesIterator(mode);
  }
}

final class _EntriesIterator
    implements Iterator<MapEntry<String, models.User>> {
  _EntriesIterator(this.mode);
  final int mode;
  var index = -1;

  @override
  bool moveNext() {
    index++;
    if (index == 1 && mode == 2) throw RangeError('moveNext failure');
    return index < 2;
  }

  @override
  MapEntry<String, models.User> get current {
    if (index == 1 && mode == 3) throw RangeError('current failure');
    return MapEntry(index == 0 ? 'first' : 'bad', _user);
  }
}
