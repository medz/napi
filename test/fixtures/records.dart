import 'package:napi/napi.dart';

import 'records_models.dart' as models;
import 'records_reexport.dart';

part 'records_part.dart';

@napi
models.User echoUser(models.User user) => user;

@napi
models.User normalizeUser(models.User user) => (
  name: user.name.trim(),
  age: user.age < 0 ? 0 : user.age,
  active: user.active ?? false,
);

@napi
Future<models.User?> echoUserAsync(models.User? user) async {
  await Future<void>.delayed(const Duration(milliseconds: 1));
  return user;
}

@napi
models.UserAlias echoAlias(models.UserAlias value) => value;

@napi
Future<models.UserAlias> echoAliasAsync(models.UserAlias value) async => value;

@napi
models.NullableUser echoNullableAlias(models.NullableUser value) => value;

@napi
Future<models.NullableUser> echoNullableAliasAsync(
  models.NullableUser value,
) async => value;

@napi
models.MaybeUserAlias echoChain(models.MaybeUserAlias value) => value;

@napi
Future<models.MaybeUserAlias> echoChainAsync(
  models.MaybeUserAlias value,
) async => value;

@napi
ReexportUser echoReexport(ReexportUser value) => value;

@napi
({String label, int count, bool? flag, double score}) echoInline(
  ({String label, int count, bool? flag, double score}) value,
) => value;

@napi
Future<({String label, int count, bool? flag, double score})?> echoInlineAsync(
  ({String label, int count, bool? flag, double score})? value,
) async => value;

@napi
models.Mixed echoMixed(models.Mixed value) => value;

@napi
Future<models.Mixed> echoMixedAsync(models.Mixed value) async {
  await Future<void>.value();
  return value;
}

@napi
models.SpecialFields echoSpecial(models.SpecialFields value) => value;

@napi
Future<models.SpecialFields> echoSpecialAsync(
  models.SpecialFields value,
) async => value;

var _calls = 0;
models.User _stored = (name: 'initial', age: 1, active: null);

@napi
int calls() => _calls;

@napi
models.User tracked(models.User first, models.User second) {
  _calls++;
  _stored = first;
  return second;
}

@napi
Future<models.User> trackedAsync(models.User first, models.User second) async {
  _calls++;
  _stored = first;
  await Future<void>.delayed(const Duration(milliseconds: 1));
  return second;
}

@napi
models.User readStored() => _stored;

@napi
Future<models.User> readStoredAsync() async => _stored;

@napi
void changeStored() => _stored = (name: 'changed', age: 2, active: true);

@napi
models.User unsafeUser() =>
    (name: 'unsafe', age: 9007199254740992, active: null);

@napi
Future<models.User> unsafeUserAsync() async => unsafeUser();

@napi
models.Mixed unsafeMixed() => (
  flag: true,
  count: 9007199254740992,
  value: -0.0,
  text: 'unsafe',
  maybeFlag: null,
  maybeCount: null,
  maybeValue: null,
  maybeText: null,
);

@napi
Future<models.Mixed> unsafeMixedAsync() async => unsafeMixed();

@napi
({int value}) inlineOne(({int value}) value) => value;

@napi
Future<({int value})> inlineOneAsync(({int value}) value) async => value;

// A function and an imported record typedef can share a TS value/type name.
@napi
// ignore: non_constant_identifier_names
models.User User(models.User user) => user;
