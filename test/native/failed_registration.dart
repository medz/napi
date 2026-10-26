import 'package:napi/env.dart';

final class Leaked {
  int value = 7;

  int increment() => ++value;
}

void register(Env env, JsObject exports) {
  env.global['failedEnvFunction'] = env.function('failedEnvFunction', (_) => 7);
  final constructor = env.defineClass<Leaked>(
    'Leaked',
    constructor: (_) => Leaked(),
    methods: {'increment': (self, _) => self.increment()},
    getters: {'value': (self) => self.value},
    setters: {'value': (self, args) => self.value = args.get<int>(0)},
  );
  env.global['failedEnvClass'] = constructor;
  env.global.get<JsFunction>('captureFailedEnvClass').call([constructor]);
  final fail = env.global['failedEnvRegistrationError'];
  if (fail is JsFunction) fail.call([]);
  throw StateError('registration failed');
}
