# napi

Node-API bindings for Dart.

## Native compilation

Declare the exports in `lib/addon.dart`:

```dart
import 'package:napi/env.dart';

void register(Env env, JsObject exports) {
  exports['add'] = env.function('add', (args) {
    return args.get<int>(0) + args.get<int>(1);
  });
}
```

Build it with your own Dart script:

```dart
import 'dart:io';
import 'package:napi/compiler.dart';

final compiler = Compiler([
  NativeTarget(
    entry: File('lib/addon.dart'),
    output: File('dist/addon.node'),
    node: '^24.0.0',
  ),
]);

Future<void> main(List<String> args) => compiler.run(args);
```

Load the result directly in Node.js:

```js
const { add } = require('./dist/addon.node');
console.log(add(20, 22)); // 42
```

The output is a standalone `.node` file for the current platform. The package
includes compilers for macOS arm64, Linux arm64 (glibc) and Windows x64; building an
addon does not require SDK sources or a C/C++ toolchain. Business code is compiled
with the bundled Dart 3.13.5 SDK, independently of the SDK running the script.
Include the corresponding SDK `NOTICES` file when redistributing the addon.

Omit `node` to infer the minimum requirements from referenced APIs. A supplied
range uses Dart version constraint syntax, with `||` for alternatives, and must
be compatible with those APIs. Compilation failures preserve an existing output.

The compiler connects `register` to the Node environment. It must be a synchronous
`void` function taking `Env` and `JsObject`. Annotation-based exports are not
implemented yet. Raw addons can still provide the `initialize`, `afterPump` and
`dispose` hooks used by the [native experiment](experiments/native-image/payload.dart).

## Classes

Use `env.defineClass<T>` to register a Dart-backed JavaScript class. Constructors
and methods receive `JsArguments`; getters receive the Dart instance, and setters
receive the instance and arguments. Calling the Dart constructor or method without
an optional argument preserves its Dart default.

The [Counter example](example/counter.dart) defines a constructor, method and
getter/setter. Run `dart run example/build.dart`, then:

```js
const { Counter } = require('./build/counter.node');
const counter = new Counter(5);
counter.increment(); // 6
counter.value = 10;
counter.increment(2); // 12
```

An instance retains its Dart object until JavaScript collects it or its environment
ends. An optional `finalize` callback can release Dart resources; it must not access
JavaScript during environment cleanup. Registration callbacks remain live for the
lifetime of their environment.

## Values and references

Arguments use strict conversions without JavaScript coercion:

- `bool`, `String`, `double` and `BigInt` map to their corresponding JS primitives.
- `int` accepts finite integral Numbers within ±9,007,199,254,740,991. Returning a
  Dart int outside that range throws a RangeError; use BigInt for larger integers.
- Nullable types accept `null`. JavaScript `undefined` is the Dart `undefined`
  constant; `args.length` distinguishes an omitted argument from a supplied one.
- Objects, functions and symbols use `JsObject`, `JsFunction` and `JsSymbol`.

JS handles are borrowed during `register`, a registered callback or
`env.withScope`. To keep an object, function or symbol across calls, use `retain()`
and read the resulting reference's `value` within a scope. Call `dispose()` when
finished; references are also released on Dart collection or environment cleanup.
Cross-heap cycles require explicit disposal. Each Env belongs to its original
Node environment and Dart isolate.

JavaScript exceptions become `JsException` in Dart; rethrowing one preserves the
original JS value. Dart ArgumentError and TypeError become JS TypeError,
RangeError becomes JS RangeError, and other Dart errors become JS Error.

## Raw bindings

Import the raw FFI bindings with:

```dart
import 'package:napi/sys/node.dart' as node;
```

These bindings expose Node-API handles, status codes and native function
signatures. Calls require a valid environment supplied by a Node-API host.

See the [native image experiment](experiments/native-image/README.md) for the
standalone Dart AOT addon prototype.
