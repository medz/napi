import '../env.dart';
import '../../sys/node.dart' as node;
import 'native_runtime.dart';

Env? _env;
NativeRuntime? _runtime;

int initialize(
  int environment,
  int exports,
  int callJs,
  int owner,
  int finalizer,
  int hasLivePorts,
  void Function(Env, JsObject) register,
) {
  final runtime = NativeRuntime(
    node.NapiEnv.fromAddress(environment),
    callJs,
    owner,
    finalizer,
    hasLivePorts,
  );
  _runtime = runtime;
  final env = createEnv(runtime);
  _env = env;
  registerEnv(env, node.NapiValue.fromAddress(exports), register);
  runtime.wake();
  return runtime.threadsafeAddress;
}

void afterPump() => _runtime?.afterPump();

void dispose() {
  // Closing the notification port precedes releasing any Dart objects.
  _runtime?.close();
  try {
    final env = _env;
    if (env != null) disposeEnv(env);
  } finally {
    _env = null;
    _runtime = null;
  }
}
