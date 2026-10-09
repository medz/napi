import 'package:napi/napi.dart';

typedef User = ({String name, int age, bool? active});

@napi
User normalize(User user) =>
    (name: user.name.trim(), age: user.age, active: user.active);

@napi
Future<User?> normalizeLater(User? user) async {
  await Future<void>.delayed(const Duration(milliseconds: 1));
  return user == null ? null : normalize(user);
}

@napi
List<User> normalizeUsers(List<User> users) => [
  for (final user in users) normalize(user),
];

@napi
Future<List<User?>?> normalizeUsersLater(List<User?>? users) async {
  if (users == null) return null;
  await Future<void>.delayed(const Duration(milliseconds: 1));
  return [for (final user in users) user == null ? null : normalize(user)];
}
