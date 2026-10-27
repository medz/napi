import 'dart:async';

import 'package:napi/env.dart';
import 'package:napi/napi.dart';

JsReference<JsObject> _object(Env env, int value) {
  final object = env.object();
  object.defineValue('value', value);
  return object.retain();
}

@NAPI()
JsReference<JsObject> makeObject(Env env, int value) => _object(env, value);

@NAPI()
Future<JsReference<JsObject>> asyncObject(Env env) async {
  await Future<void>.delayed(Duration.zero);
  return env.withScope(() => _object(env, 11));
}

@NAPI()
class Session {
  @NAPI()
  Session(this.name, Env owner, [this.count = 2]) : _owner = owner;

  final Env _owner;

  @NAPI()
  final String name;

  @NAPI()
  int count;

  @NAPI()
  bool sameOwner(Env env) => identical(env, _owner);

  @NAPI()
  int compute(int value, {required Env env, int a = 1, int b = 2}) {
    if (!identical(env, _owner)) throw StateError('Wrong environment');
    return value + a + b + count;
  }

  @NAPI()
  static JsReference<JsObject> create(Env env, int value) =>
      _object(env, value);
}

class _Derived extends Session {
  _Derived(Env env) : super('derived', env);

  @override
  int compute(int value, {required Env env, int a = 3, int b = 4}) =>
      super.compute(value, env: env, a: a, b: b);
}

@NAPI()
Session derivedSession(Env env) => _Derived(env);

@NAPI.object()
class Stamp {
  @NAPI()
  Stamp({required Env env, required this.value}) : object = _object(env, value);

  @NAPI()
  final int value;

  @NAPI()
  final JsReference<JsObject> object;
}

@NAPI()
Stamp echoStamp(Stamp value) => value;
