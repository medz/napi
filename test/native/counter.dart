import 'package:napi/env.dart';

final class Counter {
  Counter([this.value = 0]);

  int value;

  int increment([int step = 1]) {
    final next = value + step;
    if (next.abs() > 9007199254740991) {
      throw RangeError('Result exceeds JavaScript safe integers');
    }
    return value = next;
  }
}

final class Other {}

void register(Env env, JsObject exports) {
  final finalized = <int>{};
  JsReference<JsFunction>? saved;
  exports['Counter'] = env.defineClass<Counter>(
    'Counter',
    constructor: (args) => args.isEmpty ? Counter() : Counter(args.get<int>(0)),
    methods: {
      'increment': (self, args) =>
          args.isEmpty ? self.increment() : self.increment(args.get<int>(0)),
    },
    getters: {'value': (self) => self.value},
    setters: {'value': (self, args) => self.value = args.get<int>(0)},
    finalize: (self) => finalized.add(self.value),
  );
  exports['Other'] = env.defineClass<Other>(
    'Other',
    constructor: (_) => Other(),
  );
  exports['echoInt'] = env.function('echoInt', (args) => args.get<int>(0));
  exports['returnMinInt'] = env.function(
    'returnMinInt',
    (_) => -9223372036854775808,
  );
  exports['echoNullableInt'] = env.function(
    'echoNullableInt',
    (args) => args.get<int?>(0),
  );
  exports['echoDouble'] = env.function(
    'echoDouble',
    (args) => args.get<double>(0),
  );
  exports['echoNullableDouble'] = env.function(
    'echoNullableDouble',
    (args) => args.get<double?>(0),
  );
  exports['echoBool'] = env.function('echoBool', (args) => args.get<bool>(0));
  exports['echoString'] = env.function(
    'echoString',
    (args) => args.get<String>(0),
  );
  exports['echoBigInt'] = env.function(
    'echoBigInt',
    (args) => args.get<BigInt>(0),
  );
  exports['presence'] = env.function('presence', (args) {
    if (args.isEmpty) return 'missing';
    final value = args[0];
    if (identical(value, undefined)) return 'undefined';
    if (value == null) return 'null';
    return 'value';
  });
  exports['invoke'] = env.function('invoke', (args) {
    return args.get<JsFunction>(0).call([
      for (var i = 1; i < args.length; ++i) args[i],
    ]);
  });
  exports['scopedInvoke'] = env.function(
    'scopedInvoke',
    (args) => env.withScope(() => args.get<JsFunction>(0).call([])),
  );
  exports['malformedException'] = env.function('malformedException', (_) {
    throw JsException(DateTime.now());
  });
  exports['saveCallback'] = env.function('saveCallback', (args) {
    final next = args.get<JsFunction>(0).retain();
    saved?.dispose();
    saved = next;
    return undefined;
  });
  exports['callSaved'] = env.function('callSaved', (args) {
    final callback = saved;
    if (callback == null) throw StateError('No callback has been saved');
    return callback.value.call([args[0]]);
  });
  exports['clearSaved'] = env.function('clearSaved', (_) {
    saved?.dispose();
    saved = null;
    return undefined;
  });
  exports['wasFinalized'] = env.function(
    'wasFinalized',
    (args) => finalized.contains(args.get<int>(0)),
  );
  exports['scopeBorrowed'] = env.function('scopeBorrowed', (args) {
    final callback = env.withScope(() => args.get<JsFunction>(0));
    return callback.call([]);
  });
  exports['scopeRetained'] = env.function('scopeRetained', (args) {
    final callback = env.withScope(() => args.get<JsFunction>(0).retain());
    try {
      return callback.value.call([]);
    } finally {
      callback.dispose();
    }
  });
}
