import 'package:napi/env.dart';

class Counter {
  Counter([this.value = 0]);

  int value;

  int increment([int step = 1]) {
    final next = value + step;
    if (next < -9007199254740991 || next > 9007199254740991) {
      throw RangeError('Result exceeds JavaScript safe integers');
    }
    return value = next;
  }
}

void register(Env env, JsObject exports) {
  exports['Counter'] = env.defineClass<Counter>(
    'Counter',
    constructor: (args) => args.isEmpty ? Counter() : Counter(args.get<int>(0)),
    methods: {
      'increment': (self, args) =>
          args.isEmpty ? self.increment() : self.increment(args.get<int>(0)),
    },
    getters: {'value': (self) => self.value},
    setters: {'value': (self, args) => self.value = args.get<int>(0)},
  );
}
