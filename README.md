# napi

Node-API bindings for Dart.

## Native compilation

Annotate functions in `lib/addon.dart`:

```dart
import 'package:napi/napi.dart';

@NAPI()
int add(int a, int b) => a + b;
```

Build it with your own Dart script:

```dart
import 'dart:io';
import 'package:napi/compiler.dart';

final compiler = Compiler([
  NativeTarget(
    entry: File('lib/addon.dart'),
    output: File('dist/addon.node'),
    declarations: File('dist/addon.d.ts'),
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

Omit `declarations` to generate only the binary. Declaration output requires
annotated exports. Functions support positional parameters, named options,
nullable values and Dart defaults. A named parameter group becomes the final JS
options argument. Explicit `undefined` is a value; it does not select a Dart
default. For optional options fields, enable TypeScript's
`exactOptionalPropertyTypes` to reject invalid explicit `undefined` statically.

Use `@NAPI(name: 'anotherName')` to change an export's name. Exports are selected
from the entry library and its re-exports. An explicitly annotated private
function can be exported. Unsupported declarations and conflicting names produce
a build error.

## Classes

Annotate a Dart class to expose its public constructors, methods and properties:

```dart
import 'package:napi/napi.dart';

@NAPI()
class Counter {
  Counter([this.value = 0]);

  int value;
  int increment([int step = 1]) => value += step;
  Counter same() => this;
}
```

Run the [Counter example](example/counter.dart) with
`dart run example/build.dart`, then:

```js
const { Counter } = require('./build/counter.node');
const counter = new Counter(5);
counter.increment(); // 6
counter.value = 10;
counter.increment(2); // 12
counter.same() === counter; // true
```

Named constructors become static factories, such as `Counter.named(options)`.
Static Dart members are properties of the JS constructor. Final fields and
getters without setters are read-only. Private members stay private unless
explicitly annotated. Class export names must also be valid TypeScript class
names. Method calls preserve the actual Dart implementation's
defaults, including when a function returns an unexported subclass.

Passing a bound instance back to Dart unwraps the original object. Returning that
object again reuses its live JS instance. JavaScript collection releases the
binding's Dart reference. Inheritance between exported classes is not supported
yet; the compiler rejects those declarations. Returning the same object through
two different exported class types is rejected while its first wrapper is alive.

## npm packages

Use `PackageBuild` in your Dart build script to produce an installable package:

```dart
final compiler = Compiler([
  PackageBuild(
    entry: File('lib/addon.dart'),
    output: Directory('dist/npm'),
    name: '@acme/addon',
    version: '1.0.0',
  ),
]);
```

The output includes the native addon, runtime notices, CJS/ESM entries and
TypeScript declarations. Consumers install it with `npm install ./dist/npm`:

```js
import { add } from '@acme/addon';
console.log(add(20, 22)); // 42
```

`require('@acme/addon')` exposes the same bindings. Package entries require
Node.js 12.22 or later, plus any newer version required by the exported APIs.
No install-time compilation is needed.

For multiple platforms, build on each platform and keep its output directory,
including `.napi.json`. Assemble the artifacts in a separate build script:

```dart
final compiler = Compiler([
  PackageBuild.fromArtifacts(
    artifacts: [
      NativeArtifact(File('macos/.napi.json')),
      NativeArtifact(File('linux/.napi.json')),
      NativeArtifact(File('windows/.napi.json')),
    ],
    output: Directory('dist/npm'),
    name: '@acme/addon',
    version: '1.0.0',
  ),
]);
```

Assembly does not run the compiler or load foreign addons. Artifacts must expose
the same declarations. Publish the packages under `platforms/` before publishing
the root package; npm selects the matching platform dependency. The root package
also loads directly from the complete build directory.

Choose an empty output directory or a previous `PackageBuild` output. Rebuilds
reject unknown files instead of deleting them. Switching output directories can
briefly make the package unavailable; a failed switch restores the old directory.

## Manual registration

For low-level bindings, use `void register(Env env, JsObject exports)` instead:

```dart
import 'package:napi/env.dart';

void register(Env env, JsObject exports) {
  exports.defineValue('add', env.function('add', (args) {
    return args.get<int>(0) + args.get<int>(1);
  }));
}
```

The compiler connects this synchronous entry to the Node environment. Manual
registration and annotation exports are separate entry modes. Raw addons can
also provide the `initialize`, `afterPump` and `dispose` hooks used by the
[native experiment](experiments/native-image/payload.dart).

Use `env.defineClass<T>` for explicit class bindings. Instance methods and setters
receive `(T, JsArguments)`; instance getters receive `T`. Constructors, static
methods and static setters receive only `JsArguments`; static getters take no
arguments. An optional `finalize` callback can release resources; it must not access
JavaScript during environment cleanup. Registration callbacks remain live until
their environment ends.

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
