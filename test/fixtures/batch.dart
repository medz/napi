import 'dart:collection';
import 'dart:typed_data';

import 'package:napi/napi.dart';

import 'records_models.dart' as models;

part 'batch_part.dart';

typedef ReadonlyArray = ({int count});

@napi
List<models.User> normalizeUsers(List<models.User> users) => [
  for (final user in users)
    (
      name: user.name.trim(),
      age: user.age < 0 ? 0 : user.age,
      active: user.active ?? false,
    ),
];

@napi
Future<List<models.User>> normalizeUsersAsync(List<models.User> users) async {
  await Future<void>.delayed(const Duration(milliseconds: 1));
  return normalizeUsers(users);
}

@napi
int totalAge(List<models.User> users) =>
    users.fold(0, (total, user) => total + user.age);

@napi
Future<int> totalAgeAsync(List<models.User> users) async => totalAge(users);

@napi
List<ReadonlyArray> echoReadonlyArrays(List<ReadonlyArray> values) => values;

@napi
List<models.User> echoUsers(List<models.User> values) => values;

@napi
Future<List<models.User>> echoUsersAsync(List<models.User> values) async {
  await Future<void>.delayed(const Duration(milliseconds: 1));
  return values;
}

@napi
List<models.User?> echoNullableUsers(List<models.User?> values) => values;

@napi
Future<List<models.User?>> echoNullableUsersAsync(
  List<models.User?> values,
) async => values;

@napi
List<models.User>? echoNullableContainerUsers(List<models.User>? values) =>
    values;

@napi
Future<List<models.User>?> echoNullableContainerUsersAsync(
  List<models.User>? values,
) async => values;

@napi
List<models.User?>? echoNullableBothUsers(List<models.User?>? values) => values;

@napi
Future<List<models.User?>?> echoNullableBothUsersAsync(
  List<models.User?>? values,
) async => values;

@napi
List<models.Mixed> echoMixed(List<models.Mixed> values) => values;

@napi
Future<List<models.Mixed>> echoMixedAsync(List<models.Mixed> values) async =>
    values;

@napi
List<models.MaybeUserAlias> echoNullableAlias(
  List<models.MaybeUserAlias> values,
) => values;

@napi
Future<List<models.MaybeUserAlias>> echoNullableAliasAsync(
  List<models.MaybeUserAlias> values,
) async => values;

@napi
List<models.UserAlias> echoChain(List<models.UserAlias> values) => values;

@napi
Future<List<models.UserAlias>> echoChainAsync(
  List<models.UserAlias> values,
) async => values;

@napi
List<({String label, int count, bool? flag, double score})?>? echoInline(
  List<({String label, int count, bool? flag, double score})?>? values,
) => values;

@napi
Future<List<({String label, int count, bool? flag, double score})?>?>
echoInlineAsync(
  List<({String label, int count, bool? flag, double score})?>? values,
) async => values;

@napi
List<models.SpecialFields> echoSpecial(List<models.SpecialFields> values) =>
    values;

@napi
Future<List<models.SpecialFields>> echoSpecialAsync(
  List<models.SpecialFields> values,
) async => values;

var _calls = 0;
List<models.User> _stored = [];

@napi
int calls() => _calls;

@napi
List<models.User> tracked(List<models.User> first, List<models.User> second) {
  _calls++;
  _stored = first;
  return second;
}

@napi
Future<List<models.User>> trackedAsync(
  List<models.User> first,
  List<models.User> second,
) async {
  _calls++;
  _stored = first;
  await Future<void>.delayed(const Duration(milliseconds: 1));
  return second;
}

@napi
List<models.User> readStored() => _stored;

@napi
Future<List<models.User>> readStoredAsync() async => _stored;

@napi
void changeStored() {
  _stored[0] = (name: 'changed', age: 2, active: true);
  _stored.add((name: 'appended', age: 3, active: null));
}

@napi
List<models.User> repeatFirst(List<models.User> values) => [
  values.first,
  values.first,
];

@napi
Future<List<models.User>> repeatFirstAsync(List<models.User> values) async =>
    repeatFirst(values);

@napi
List<models.User> unsafeUsers() => [
  (name: 'valid', age: 1, active: true),
  (name: 'valid', age: 2, active: null),
  (name: 'unsafe', age: 9007199254740992, active: null),
];

@napi
Future<List<models.User>> unsafeUsersAsync() async => unsafeUsers();

@napi
List<models.Mixed> unsafeMixed() => [
  (
    flag: true,
    count: 9007199254740992,
    value: -0.0,
    text: 'unsafe',
    maybeFlag: null,
    maybeCount: null,
    maybeValue: null,
    maybeText: null,
  ),
];

@napi
Future<List<models.Mixed>> unsafeMixedAsync() async => unsafeMixed();

var _invalidIndexReads = 0;

final class _InvalidLengthUsers extends ListBase<models.User> {
  _InvalidLengthUsers(this._length);

  final int _length;

  @override
  int get length => _length;

  @override
  set length(int value) => throw StateError('Unused length setter');

  @override
  models.User operator [](int index) {
    _invalidIndexReads++;
    throw StateError('Invalid-length output must not read an element');
  }

  @override
  void operator []=(int index, models.User value) =>
      throw StateError('Unused element setter');
}

@napi
List<models.User> invalidLengthUsers(int length) => _InvalidLengthUsers(length);

@napi
Future<List<models.User>> invalidLengthUsersAsync(int length) async =>
    invalidLengthUsers(length);

@napi
int invalidIndexReads() => _invalidIndexReads;

@napi
List<models.Packet> echoPackets(List<models.Packet> values) => values;

@napi
Future<List<models.Packet>> echoPacketsAsync(List<models.Packet> values) async {
  await Future<void>.delayed(const Duration(milliseconds: 1));
  return values;
}

@napi
List<models.Packet> normalizePackets(List<models.Packet> values) {
  for (var row = 0; row < values.length; row++) {
    final value = values[row];
    for (var index = 0; index < value.payload.length; index++) {
      value.payload[index] ^= 0xff;
    }
    values[row] = (name: value.name.trim(), payload: value.payload);
  }
  return values;
}

@napi
Future<List<models.Packet>> normalizePacketsAsync(
  List<models.Packet> values,
) async {
  await Future<void>.delayed(const Duration(milliseconds: 1));
  return normalizePackets(values);
}

@napi
List<models.MaybePacket>? echoNullablePackets(
  List<models.MaybePacket>? values,
) => values;

@napi
Future<List<models.MaybePacket>?> echoNullablePacketsAsync(
  List<models.MaybePacket>? values,
) async => values;

@napi
List<({String name, Uint8List? payload})?>? echoInlinePackets(
  List<({String name, Uint8List? payload})?>? values,
) => values;

@napi
Future<List<({String name, Uint8List? payload})?>?> echoInlinePacketsAsync(
  List<({String name, Uint8List? payload})?>? values,
) async => values;

@napi
List<models.ByteFields> echoByteFieldsList(List<models.ByteFields> values) {
  _calls++;
  return values;
}

@napi
Future<List<models.ByteFields>> echoByteFieldsListAsync(
  List<models.ByteFields> values,
) async {
  _calls++;
  return values;
}

@napi
List<models.Packet> repeatFirstPacket(List<models.Packet> values) => [
  values.first,
  values.first,
];

@napi
Future<List<models.Packet>> repeatFirstPacketAsync(
  List<models.Packet> values,
) async => repeatFirstPacket(values);

List<models.Packet> _storedPackets = [];

@napi
List<models.Packet> trackedPackets(
  List<models.Packet> first,
  List<models.Packet> second,
) {
  _calls++;
  if (first.first.name == 'fail') throw ArgumentError('packet failure');
  _storedPackets = first;
  return second;
}

@napi
Future<List<models.Packet>> trackedPacketsAsync(
  List<models.Packet> first,
  List<models.Packet> second,
) async {
  _calls++;
  if (first.first.name == 'fail') throw ArgumentError('packet failure');
  _storedPackets = first;
  await Future<void>.delayed(const Duration(milliseconds: 1));
  return second;
}

@napi
List<models.Packet> readPackets() => _storedPackets;

@napi
Future<List<models.Packet>> readPacketsAsync() async => _storedPackets;

@napi
void changePackets() {
  if (_storedPackets.first.payload.isNotEmpty) {
    _storedPackets.first.payload[0] ^= 0xff;
  }
  _storedPackets.add(_storedPackets.first);
}
