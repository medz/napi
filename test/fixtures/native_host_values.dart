// Handwritten private ABI fixture. This does not exercise annotation lowering
// or claim that exported opaque generic declarations are supported.
import 'dart:async';
import 'dart:ffi';

import 'package:napi/src/compiler/native/bindings.dart';

late final NapiApi _api;
late final NapiApi _otherApi;
NativeHostValue? _saved;
_Router? _pinned;
var _zoneCalls = 0;
var _releasedLater = false;
List<int> _allocation = [];

final class _Router {
  NativeHostValue? value;
  _Router(this.value);

  void clear() {
    final previous = value;
    value = null;
    previous?.release();
  }
}

int _run(int env, int info, int capacity, int Function(NapiCall) body) {
  try {
    return body(_api.call(env, info, capacity));
  } catch (error) {
    return _api.fail(env, error);
  }
}

_Router _receiver(NapiCall call) => _api.owner(call) as _Router;

NativeHostValue _own(NapiCall call) {
  // Explicit undefined is a value here. Ordinary argument presence conversion
  // belongs to the future generated opaque binding layer, not this primitive.
  if (call.argumentCount == 0) throw StateError('Fixture value is required');
  return _api.ownHostValue(call.env, call.arguments[0]);
}

int _save(int env, int info) => _run(env, info, 1, (call) {
  final value = _own(call);
  final previous = _saved;
  _saved = value;
  previous?.release();
  return _api.undefinedResult(call.env);
});

int _get(int env, int info) =>
    _run(env, info, 0, (call) => _api.hostValue(call.env, _saved!).address);

int _clear(int env, int info) => _run(env, info, 0, (call) {
  final previous = _saved;
  _saved = null;
  previous?.release();
  previous?.release();
  return _api.undefinedResult(call.env);
});

int _forget(int env, int info) => _run(env, info, 0, (call) {
  _saved = null;
  return _api.undefinedResult(call.env);
});

int _release(int env, int info) => _run(env, info, 0, (call) {
  _saved!.release();
  _saved!.release();
  return _api.undefinedResult(call.env);
});

int _constructor(int env, int info) => _run(env, info, 1, (call) {
  _api.checkNew(call, true, 'HostRouter');
  return _api.wrap(call, _Router(_own(call)), 0);
});

int _routerGet(int env, int info) => _run(
  env,
  info,
  0,
  (call) => _api.hostValue(call.env, _receiver(call).value!).address,
);

int _routerSet(int env, int info) => _run(env, info, 1, (call) {
  final router = _receiver(call);
  final value = _own(call);
  router.clear();
  router.value = value;
  return _api.undefinedResult(call.env);
});

int _routerClear(int env, int info) => _run(env, info, 0, (call) {
  _receiver(call).clear();
  return _api.undefinedResult(call.env);
});

int _routerForget(int env, int info) => _run(env, info, 0, (call) {
  // Ordinary business code breaks ownership by removing its field, without
  // knowing about the compiler-private carrier or calling its release method.
  _receiver(call).value = null;
  return _api.undefinedResult(call.env);
});

int _pin(int env, int info) => _run(env, info, 0, (call) {
  _pinned = _receiver(call);
  return _api.undefinedResult(call.env);
});

int _readopt(int env, int info) => _run(
  env,
  info,
  0,
  (call) => _api.referenceResult(call.env, _pinned!, 0, 'readopt'),
);

int _unpin(int env, int info) => _run(env, info, 0, (call) {
  _pinned = null;
  return _api.undefinedResult(call.env);
});

int _wrongApi(int env, int info) => _run(
  env,
  info,
  0,
  (call) => _otherApi.hostValue(call.env, _saved!).address,
);

int _wrongEnv(int env, int info) => _run(
  env,
  info,
  0,
  (call) => _api.hostValue(Pointer<Void>.fromAddress(env + 1), _saved!).address,
);

int _zoneSave(int env, int info) => _run(env, info, 1, (call) {
  runZoned(
    () => _saved = _own(call),
    zoneSpecification: ZoneSpecification(
      registerUnaryCallback: <R, T>(self, parent, zone, callback) {
        _zoneCalls++;
        throw StateError('Business Zone intercepted finalizer callback');
      },
      handleUncaughtError: (self, parent, zone, error, stack) {
        _zoneCalls++;
      },
    ),
  );
  return _api.undefinedResult(call.env);
});

int _zoneCount(int env, int info) => _run(
  env,
  info,
  0,
  (call) => _api.integerResult(call.env, _zoneCalls, 'zoneCount'),
);

int _pressure(int env, int info) => _run(env, info, 1, (call) {
  final seed = _api.integer(call.env, call.arguments[0], 'pressure');
  // Live allocation makes both the work and its last use observable in AOT.
  _allocation = List<int>.generate(1000000, (index) => index + seed);
  return _api.integerResult(call.env, _allocation.last, 'pressure result');
});

int _churn(int env, int info) => _run(env, info, 1, (call) {
  for (var index = 0; index < 512; index++) {
    final value = _own(call);
    if (index.isEven) value.release();
  }
  return _api.undefinedResult(call.env);
});

int _releaseLater(int env, int info) => _run(env, info, 0, (call) {
  final value = _saved!;
  _saved = null;
  Timer(const Duration(milliseconds: 10), () {
    value.release();
    value.release();
    _releasedLater = true;
  });
  return _api.undefinedResult(call.env);
});

int _laterDone(int env, int info) =>
    _run(env, info, 0, (call) => _api.booleanResult(call.env, _releasedLater));

int _holdTimer(int env, int info) => _run(env, info, 0, (call) {
  Timer(const Duration(minutes: 1), () {});
  return _api.undefinedResult(call.env);
});

@pragma('vm:entry-point')
List<Object?> napiBindings(int address, int count) {
  _api = NapiApi(address, count);
  _otherApi = NapiApi(address, count);
  return [
    ['function', 'save', _save, 1],
    ['function', 'get', _get, 0],
    ['function', 'clear', _clear, 0],
    ['function', 'forget', _forget, 0],
    ['function', 'release', _release, 0],
    ['function', 'readopt', _readopt, 0],
    ['function', 'unpin', _unpin, 0],
    ['function', 'wrongApi', _wrongApi, 0],
    ['function', 'wrongEnv', _wrongEnv, 0],
    ['function', 'zoneSave', _zoneSave, 1],
    ['function', 'zoneCount', _zoneCount, 0],
    ['function', 'pressure', _pressure, 1],
    ['function', 'churn', _churn, 1],
    ['function', 'releaseLater', _releaseLater, 0],
    ['function', 'laterDone', _laterDone, 0],
    ['function', 'holdTimer', _holdTimer, 0],
    [
      'class',
      'HostRouter',
      _constructor,
      [
        ['method', 'get', _routerGet, 0],
        ['method', 'set', _routerSet, 1],
        ['method', 'clear', _routerClear, 0],
        ['method', 'forget', _routerForget, 0],
        ['method', 'pin', _pin, 0],
      ],
      1,
    ],
  ];
}

@pragma('vm:entry-point')
void releaseOwner(int id) => _api.releaseOwner(id);

void main() {}
