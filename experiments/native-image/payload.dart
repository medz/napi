import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'node_api.dart';

late NodeApi _node;
late bool Function() _hasLivePorts;
final _functions = <NativeCallable<NapiCallback>>[];
var _threadsafe = 0;
var _operations = 0;
var _referenced = false;
var _closing = false;
var _wakePending = false;

@pragma('vm:entry-point')
int initialize(
  int envAddress,
  int exportsAddress,
  int callJsAddress,
  int ownerAddress,
  int finalizerAddress,
  int hasLivePortsAddress,
) {
  _node = NodeApi(Js.fromAddress(envAddress));
  _hasLivePorts = Pointer<NativeFunction<Bool Function()>>.fromAddress(
    hasLivePortsAddress,
  ).asFunction<bool Function()>();
  _threadsafe = _node.threadsafe(
    Pointer<NativeFunction<NapiThreadsafeCallback>>.fromAddress(callJsAddress),
    ownerAddress,
    finalizer: Pointer<NativeFunction<NapiFinalizer>>.fromAddress(
      finalizerAddress,
    ),
  );
  Pointer<UintPtr>.fromAddress(ownerAddress).value = _threadsafe;
  _node.unrefThreadsafe(_threadsafe);
  final exports = Js.fromAddress(exportsAddress);
  _node.set(exports, 'answer', _node.numberValue(42));
  void export(String name, Js Function(Js, Js) callback) {
    final callable = NativeCallable<NapiCallback>.isolateLocal(callback);
    callable.keepIsolateAlive = false;
    _functions.add(callable);
    _node.set(exports, name, _node.function(name, callable.nativeFunction, 0));
  }

  export('add', _add);
  export('environment', _environment);
  export('readFileSync', _readFileSync);
  export('readFile', _readFile);
  export('fileRoundtrip', _fileRoundtrip);
  export('processRoundtrip', _processRoundtrip);
  export('backgroundFile', _backgroundFile);
  export('spawnBackgroundFile', _spawnBackgroundFile);
  export('unhandledError', _unhandledError);
  export('delay', _delay);
  export('httpRoundtrip', _httpRoundtrip);
  export('isolateRun', _isolateRun);
  export('isolateReadFile', _isolateReadFile);
  export('isolateSpawn', _isolateSpawn);
  export('isolateFailure', _isolateFailure);
  return _threadsafe;
}

void _updateReference() {
  if (_closing) return;
  final needed = _operations != 0 || _hasLivePorts() || _wakePending;
  if (needed == _referenced) return;
  if (needed) {
    _node.refThreadsafe(_threadsafe);
  } else {
    _node.unrefThreadsafe(_threadsafe);
  }
  _referenced = needed;
}

void _wake() {
  if (_closing || _wakePending) return;
  _wakePending = true;
  _updateReference();
  _node.wakeThreadsafe(_threadsafe);
}

@pragma('vm:entry-point')
void afterPump() {
  _wakePending = false;
  _updateReference();
}

@pragma('vm:entry-point')
void dispose() {
  _closing = true;
  for (final callback in _functions) {
    callback.close();
  }
  _functions.clear();
}

Js _guard(Js Function() body) {
  try {
    return body();
  } catch (error) {
    _node.throwError(error, typeError: true);
    return nullptr;
  } finally {
    _wake();
  }
}

int _integer(Js value) {
  if (_node.type(value) != 3) {
    throw ArgumentError('Expected a safe integer');
  }
  final number = _node.number(value);
  if (!number.isFinite ||
      number.truncateToDouble() != number ||
      number.abs() > 9007199254740991) {
    throw ArgumentError('Expected a safe integer');
  }
  return number.toInt();
}

Js _number(int value) {
  if (value.abs() > 9007199254740991) {
    throw RangeError('Result exceeds JavaScript safe integers');
  }
  return _node.numberValue(value);
}

Js _argument(Js info) {
  final arguments = _node.arguments(info).values;
  if (arguments.isEmpty) throw ArgumentError('Expected an argument');
  return arguments.first;
}

Js _promise(Future<Object> Function() work) {
  final (promise, deferred) = _node.promise();
  _operations++;
  _updateReference();
  Future<void> settle() async {
    try {
      final value = await work();
      final result = switch (value) {
        String() => _node.string(value),
        int() => _number(value),
        _ => throw StateError('Unsupported result: ${value.runtimeType}'),
      };
      _node.resolve(deferred, result);
    } catch (error) {
      _node.reject(deferred, _node.error('$error'));
    } finally {
      _operations--;
      _updateReference();
    }
  }

  unawaited(settle());
  _wake();
  return promise;
}

Js _add(Js env, Js info) => _guard(() {
  final arguments = _node.arguments(info).values;
  if (arguments.length != 2) {
    throw ArgumentError('Expected two safe integers');
  }
  return _number(_integer(arguments[0]) + _integer(arguments[1]));
});

Js _readFileSync(Js env, Js info) => _guard(() {
  final path = _node.text(_argument(info));
  return _node.string(File(path).readAsStringSync());
});

Js _environment(Js env, Js info) => _guard(
  () => _node.string(
    jsonEncode({
      'executable': Platform.executable,
      'resolvedExecutable': Platform.resolvedExecutable,
      'operatingSystem': Platform.operatingSystem,
      'pid': pid,
      'current': Directory.current.path,
      'base': Uri.base.toString(),
      'secureByte': Random.secure().nextInt(256),
    }),
  ),
);

Js _readFile(Js env, Js info) => _guard(() {
  final path = _node.text(_argument(info));
  return _promise(() => File(path).readAsString());
});

Js _fileRoundtrip(Js env, Js info) => _guard(() {
  final arguments = _node.arguments(info).values;
  if (arguments.length != 2) {
    throw ArgumentError('Expected a file path and text');
  }
  final path = _node.text(arguments[0]);
  final text = _node.text(arguments[1]);
  return _promise(() async {
    final file = File(path);
    await file.writeAsString(text);
    return file.readAsString();
  });
});

Js _processRoundtrip(Js env, Js info) => _guard(() {
  final text = _node.text(_argument(info));
  return _promise(() async {
    final result = await Process.run('/usr/bin/printf', ['%s', text]);
    if (result.exitCode != 0) {
      throw ProcessException(
        '/usr/bin/printf',
        ['%s', text],
        '${result.stderr}',
        result.exitCode,
      );
    }
    return result.stdout as String;
  });
});

Js _backgroundFile(Js env, Js info) => _guard(() {
  final path = _node.text(_argument(info));
  Timer(const Duration(milliseconds: 20), () async {
    await File(path).writeAsString('Dart background task');
  });
  return _node.undefined();
});

Js _unhandledError(Js env, Js info) => _guard(() {
  scheduleMicrotask(() => throw StateError('Dart microtask failure'));
  return _node.undefined();
});

Js _spawnBackgroundFile(Js env, Js info) => _guard(() {
  final path = _node.text(_argument(info));
  return _promise(() => _spawnBackground(path));
});

Future<String> _spawnBackground(String path) async {
  final port = ReceivePort();
  try {
    await Isolate.spawn(
      _backgroundEntry,
      (port.sendPort, path),
      onError: port.sendPort,
      onExit: port.sendPort,
    );
    final message = await port.first;
    if (message == 'started') return 'started';
    throw StateError('Child isolate failed: $message');
  } finally {
    port.close();
  }
}

void _backgroundEntry((SendPort, String) message) {
  Timer(const Duration(milliseconds: 150), () async {
    await File(message.$2).writeAsString('Dart child background task');
  });
  message.$1.send('started');
}

Js _delay(Js env, Js info) => _guard(() {
  final milliseconds = _integer(_argument(info));
  if (milliseconds < 0) throw ArgumentError('Expected a nonnegative delay');
  return _promise(
    () => Future.delayed(
      Duration(milliseconds: milliseconds),
      () => milliseconds,
    ),
  );
});

Js _httpRoundtrip(Js env, Js info) => _guard(() {
  final text = _node.text(_argument(info));
  return _promise(() => _http(text));
});

Future<String> _http(String text) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final response = server.first.then((request) async {
    final body = await utf8.decoder.bind(request).join();
    request.response.headers.contentType = ContentType(
      'text',
      'plain',
      charset: 'utf-8',
    );
    request.response.write('Dart HTTP: $body');
    await request.response.close();
  });
  final client = HttpClient()..findProxy = (_) => 'DIRECT';
  try {
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:${server.port}/'),
    );
    request.headers.contentType = ContentType(
      'text',
      'plain',
      charset: 'utf-8',
    );
    request.write(text);
    final reply = await request.close();
    final result = await utf8.decoder.bind(reply).join();
    await response;
    return result;
  } finally {
    client.close(force: true);
    await server.close(force: true);
  }
}

Js _isolateRun(Js env, Js info) => _guard(() {
  final value = _integer(_argument(info));
  return _promise(() => Isolate.run(() => value * 2));
});

Js _isolateReadFile(Js env, Js info) => _guard(() {
  final path = _node.text(_argument(info));
  return _promise(() => Isolate.run(() => File(path).readAsStringSync()));
});

Js _isolateSpawn(Js env, Js info) => _guard(() {
  final value = _integer(_argument(info));
  return _promise(() => _spawn(value));
});

Future<int> _spawn(int value) async {
  final port = ReceivePort();
  try {
    await Isolate.spawn(
      _spawnEntry,
      (port.sendPort, value),
      onError: port.sendPort,
      onExit: port.sendPort,
    );
    final message = await port.first;
    if (message is int) return message;
    throw StateError('Child isolate failed: $message');
  } finally {
    port.close();
  }
}

void _spawnEntry((SendPort, int) message) => message.$1.send(message.$2 * 2);

Js _isolateFailure(Js env, Js info) => _guard(
  () => _promise(
    () => Isolate.run<int>(() => throw StateError('Dart isolate failure')),
  ),
);

void main() {}
