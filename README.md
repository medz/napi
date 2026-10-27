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
    declarations: File('dist/addon.d.cts'),
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
annotated exports. Use `.d.cts` for CommonJS declarations, or `.d.mts` when
providing an ESM wrapper. A `.d.ts` output uses CommonJS declarations and must be
interpreted as CommonJS by the consuming package. `PackageBuild` generates both
module formats and their declarations.

Functions support positional parameters, named options,
nullable values and Dart defaults. A named parameter group becomes the final JS
options argument. Explicit `undefined` is a value; it does not select a Dart
default. For optional options fields, enable TypeScript's
`exactOptionalPropertyTypes` to reject invalid explicit `undefined` statically.

Use `@NAPI(name: 'anotherName')` to change an export's name. Exports are selected
from the entry library and its re-exports. An explicitly annotated private
function can be exported. Unsupported declarations and conflicting names produce
a build error.

## Constants

Annotate a top-level `const` to export its value:

```dart
@NAPI()
const defaultPort = 8080;

@NAPI()
const defaults = (host: 'localhost', port: defaultPort);
```

```js
const { defaultPort, defaults } = require('./dist/addon.node');
defaults.port === defaultPort; // true
```

The exported property is read-only. Its value uses the same conversions as
function results: containers become mutable JS copies, and exported class
instances retain their identity. Function and constructor tear-offs are callable
and preserve their Dart defaults. Package builds also provide ESM named exports
and TypeScript declarations for constants.

## Top-level properties

Annotate a variable, `final` field or accessor to expose a live property:

```dart
@NAPI()
int count = 0;

@NAPI()
final startedAt = DateTime.now().toIso8601String();

@NAPI()
int get doubled => count * 2;

@NAPI()
set doubled(int value) => count = value ~/ 2;
```

```js
const addon = require('./dist/addon.node');
addon.count = 3;
console.log(addon.doubled); // 6
addon.doubled = 10;
console.log(addon.count); // 5
```

Reads and writes access the Dart declaration each time. Dart field initializers
remain lazy, getters run on each read, and `final` fields are read-only. Annotate
both accessors to export both directions; an unmarked getter or setter stays in
Dart. Values use the same conversions as function arguments and results.

With `PackageBuild`, use the ESM default import for live properties:

```js
import addon from 'my-addon';
addon.count += 1;
```

Functions, classes and constants also have ESM named exports. Live properties
are available on the default package object; destructuring them reads their
current value once.

## Collections and binary data

Dart lists map to JS arrays. String-keyed maps map to JS objects:

```dart
@NAPI()
List<int> doubleValues(List<int> values) => [for (final value in values) value * 2];

@NAPI()
Map<String, int> scores(Map<String, int> values) => values;
```

Containers are copied in both directions, including nested lists and maps.
Exported class instances inside a container retain their identity. Map input
reads own enumerable string properties once and ignores inherited and symbol
properties. Missing array elements and explicit `undefined` still undergo the
declared element type's validation. Map keys must be non-nullable `String`.

Import `dart:typed_data` to exchange binary data. `Int8List`, `Uint8List`,
`Uint8ClampedList`, `Int16List`, `Uint16List`, `Int32List`, `Uint32List`,
`Float32List` and `Float64List` map to their corresponding JS TypedArrays.
`Int64List` and `Uint64List` use `BigInt64Array` and `BigUint64Array` and preserve
all 64 bits. The array kind must match; a Node Buffer is accepted
as `Uint8List`.

Binary conversion copies only the view's range. Later writes on either side do
not change the copy. A declaration of `List<int>` always produces a JS Array,
including when its Dart implementation returns a `Uint8List`.

`ByteBuffer` maps to JS `ArrayBuffer`, and `ByteData` maps to `DataView`:

```dart
@NAPI()
ByteBuffer echoBuffer(ByteBuffer value) => value;

@NAPI()
ByteData echoView(ByteData value) => value;
```

```js
const source = new Uint8Array([91, 1, 2, 3, 92]);
const result = addon.echoView(new DataView(source.buffer, 1, 3));
console.log([...new Uint8Array(result.buffer)]); // [1, 2, 3]
```

A returned `DataView` starts at offset zero in a new buffer containing only its
visible bytes. DataView and TypedArray inputs backed by `SharedArrayBuffer` are
also copied. `ByteBuffer` input requires an ordinary `ArrayBuffer`. Detached
binary inputs throw `TypeError`; binary input conversion requires Node-API 7.
SIMD types are not supported yet.

## Dates

Dart `DateTime` values map to JavaScript `Date`:

```dart
@NAPI()
DateTime addDay(DateTime value) => value.add(const Duration(days: 1));
```

```js
const result = addon.addDay(new Date('2026-01-01T00:00:00Z'));
console.log(result.toISOString()); // 2026-01-02T00:00:00.000Z
```

Dates are copied. Inputs become UTC `DateTime` values; JS Date does not preserve
a Dart local/UTC flag or a time zone. Outputs use `millisecondsSinceEpoch`,
discarding sub-millisecond precision. This follows Dart's signed timestamp
semantics: `-1` microsecond becomes `-1` millisecond. Invalid Date inputs throw a
`RangeError`; other JS types are rejected.

## Records

Use Dart records to exchange structured values:

```dart
@NAPI()
({int x, int y}) offset(({int x, int y}) point, int dx, int dy) =>
    (x: point.x + dx, y: point.y + dy);
```

```js
offset({ x: 1, y: 2 }, 3, 4); // { x: 4, y: 6 }
```

| Dart type | JavaScript shape |
| --- | --- |
| `(int, String)` | `[1, 'text']` |
| `({int x, int y})` | `{ x: 1, y: 2 }` |
| `(int, {String label})` | `{ $1: 1, label: 'text' }` |
| `()` | `[]` |

Positional records require an array of the exact length. Named and mixed
records require their own fields; inherited properties do not fill missing
fields, and unrelated properties are ignored. Each field is read once and
checked against its Dart type. Nullable fields accept `null`, not `undefined`.

Records and their containers are copied; exported class instances inside them
keep their identity. Record defaults use their actual Dart values, and fields
can contain the other supported types, including callbacks, Futures and Streams.

## Enums

Annotate an enum to expose its cases as read-only numeric properties:

```dart
@NAPI()
enum Status { ready, done }

@NAPI()
Status toggle(Status value) =>
    value == Status.ready ? Status.done : Status.ready;
```

```js
Status.ready; // 0
toggle(Status.ready) === Status.done; // true
```

Values use Dart's `index`, so reordering cases changes their numeric values.
Parameters accept only valid indices; names, fractional numbers and out-of-range
indices are rejected. TypeScript exposes a read-only object and a union of its
values, including with `isolatedModules` enabled.

Use `@NAPI(name: 'anotherName')` on the enum or a case to rename it. Private
cases must be explicitly annotated. Enhanced enum fields and methods remain
available to Dart code; expose their behavior through annotated functions.

## Classes

Annotate a Dart class and the members you want to expose:

```dart
import 'package:napi/napi.dart';

@NAPI()
class Counter {
  @NAPI()
  Counter([this.value = 0]);

  @NAPI()
  int value;

  @NAPI()
  int increment([int step = 1]) => value += step;

  @NAPI()
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

Only annotated members are exported. This includes constructors, named
constructors and static members; unannotated members stay in Dart. Without an
annotated unnamed constructor, JS cannot construct the class, but functions can
still return its instances.

Annotated named constructors become static factories, such as
`Counter.named(options)`. An annotated field provides both accessors; a `final`
field is read-only. Annotate explicit getters and setters separately to expose
each direction. Private members can be exported by annotating them.

Class export names must also be valid TypeScript class names. Method calls
preserve the actual Dart implementation's defaults, including when a function
returns an unexported subclass.

Passing a bound instance back to Dart unwraps the original object. Returning that
object again reuses its live JS instance. JavaScript collection releases the
binding's Dart reference. Inheritance between exported classes is not supported
yet; the compiler rejects those declarations. Returning the same object through
two different exported class types is rejected while its first wrapper is alive.

## Data classes as plain objects

Use `@NAPI.object()` to exchange a Dart data class as a plain JS object:

```dart
@NAPI.object()
class Point {
  @NAPI()
  const Point({required this.x, this.y = 0});

  @NAPI()
  final int x;

  @NAPI()
  final int y;
}

@NAPI()
Point move(Point point) => Point(x: point.x + 1, y: point.y);
```

```js
move({ x: 1 }); // { x: 2, y: 0 }
```

The annotated constructor defines the input properties, types and defaults.
Required properties must be present on the input object itself. Omitted optional
properties use the Dart defaults; explicit `undefined` still undergoes type
validation. Each input property is read once, and unrelated properties are
ignored.

Annotated fields and getters define the output properties. They are read once
to create a new JS object with writable properties. Dart `final` constrains the
Dart instance; it does not freeze the JS copy. Nested values use their usual
conversions, including identity preservation for bound class instances and JS
references. Field and getter renames apply to output properties; input keys
keep their constructor parameter names.

Input and output shapes may differ: constructor parameters can have defaults or
different types from the output getters. The generated TypeScript describes
each direction separately. The class name is a TypeScript interface, available
with `import type`; it does not create a JS constructor or export instance
methods.

Annotate one constructor, unnamed or named, to enable input conversion. A data
class without an annotated constructor can still be returned from Dart. Multiple
annotated constructors are ambiguous and produce a build error. Keep methods
and static members unannotated, and expose their behavior through annotated
functions when needed.

Data-object conversion supports up to 128 nested data objects. Deeper or cyclic
structures throw `RangeError`.

## Generics

Dart type parameters become TypeScript generics:

```dart
@NAPI()
T identity<T>(T value) => value;

@NAPI()
class Box<T> {
  @NAPI()
  Box(this.value);

  @NAPI()
  T value;
}
```

```ts
import { Box, identity } from 'my-addon';

const text = identity('hello'); // string
const box = new Box<number>(42);
box.value = 7;
```

TypeScript infers type arguments from values and checks explicit arguments.
These arguments are erased at runtime; Dart calls use the declaration's default
type arguments. Unconstrained parameters pass scalars directly and retain JS
objects, functions and symbols as owned references, preserving their JS
identity when returned. The same rules apply to elements of `List<T>`,
`Map<String, T>` and ordinary callback signatures.

Bounds currently support scalars, `Object` and explicit `JsReference` types.
Bounds that copy values or unwrap a bound class, non-default specializations of
generic classes at the binding boundary, and callbacks with their own type
parameters produce a build error.

## Functions and callbacks

Use ordinary Dart function types for callbacks and returned closures:

```dart
@NAPI()
int apply(int Function(int) transform, int value) => transform(value);

@NAPI()
int Function(int) multiplier(int factor) => (value) => factor * value;
```

```js
apply(value => value + 1, 41); // 42
multiplier(3)(14); // 42
```

Callbacks can be stored and called later on the same Dart isolate. Returning a
JS callback preserves its identity for signatures with symmetric conversions,
such as scalar arguments and results. Data classes, dates, `ByteBuffer`,
`ByteData`, Futures and Streams require an adapter, including when nested in a
signature, so a returned function may
differ from the original JS callback. Use `JsReference<JsFunction>` when passing
the original function without conversion.

Returning the same Dart closure through the same function type reuses its live
JS function. Different function types receive separate adapters. Collecting the
JS function releases its Dart closure and captured values. Optional arguments
keep the actual Dart function's defaults and distinguish omission from `null`
and `undefined`.

Arguments and results use the same conversions as other annotated functions,
including nested collections and exported classes. Generic function types are
not supported yet.

## JavaScript values

Use an owned reference to keep a JS object, function or Symbol in Dart:

```dart
@NAPI()
Future<JsReference<JsObject>> returnLater(JsReference<JsObject> value) async {
  await Future<void>.delayed(const Duration(milliseconds: 1));
  return value;
}
```

```js
const value = {};
await returnLater(value) === value; // true
```

`JsReference<JsObject>`, `JsReference<JsFunction>` and `JsReference<JsSymbol>`
preserve JS identity across calls. Returning a reference does not consume it.
Use `dispose()` when finished; references are also released by Dart collection
and environment cleanup. Cross-heap reference cycles require explicit disposal.
The reference's `value` is borrowed during a callback or `Env.withScope`.

`Object?` accepts any JS value: scalars become Dart values, and objects,
functions and Symbols become owned references. It generates TypeScript `unknown`;
`dynamic` generates `any`. A non-nullable `Object` rejects `null` and still accepts
JS `undefined`, represented by the exported `undefined` value. Use `JsUndefined`
when a declaration specifically requires `undefined`.

Opaque values keep their identity rather than reading object properties. They
can return Dart scalars and JS references; use a concrete supported Dart type
such as `List<int>` or a record to convert structured Dart results. Hiding a Dart
container or class behind `Object?` does not serialize it automatically.

## Futures

Return a `Future` to expose an asynchronous function, or accept one to await a
JavaScript Promise:

```dart
@NAPI()
Future<int> addLater(int value) async {
  await Future<void>.delayed(const Duration(milliseconds: 1));
  return value + 1;
}

@NAPI()
Future<int> addFromPromise(Future<int> value) async => await value + 1;
```

```js
await addLater(41); // 42
await addFromPromise(Promise.resolve(41)); // 42
```

Future parameters require a Promise. Its completed value is checked against the
declared Dart type. Completion errors reject the returned Promise, including
errors converting a Dart result; JS rejection reasons retain their identity.
`Future<void>` resolves to `undefined`. Use it instead of `async void`.

Results follow standard Promise resolution: returned thenables are adopted, and
nested Futures are flattened. Directly nested Future parameters cannot preserve
their Dart structure and are rejected during compilation. Futures inside lists
and maps are supported.

## Streams

Use a Dart `Stream` to produce or consume an async iterable:

```dart
@NAPI()
Stream<int> count(int limit) async* {
  for (var value = 0; value < limit; value++) {
    yield value;
  }
}

@NAPI()
Future<int> sum(Stream<int> values) async {
  var total = 0;
  await for (final value in values) {
    total += value;
  }
  return total;
}
```

```js
for await (const value of count(3)) {
  console.log(value); // 0, 1, 2
}
await sum((async function* () { yield 2; yield 3; })()); // 5
```

Each returned stream is a single async iterator with `next()` and `return()`.
Concurrent `next()` calls are queued. Breaking out of `for await` or calling
`return()` cancels the Dart subscription. In-flight requests keep their iterator
alive; collection of an idle iterator also cancels its subscription.

Input streams subscribe once and stop pulling while paused. Cancellation calls
the JS iterator's `return()` when available. A producer that never completes its
`return()` can also leave Dart cancellation pending.

Stream events use the same conversions as other values. Promise-valued events
are not flattened. Use `next()` when handling `Stream<Future<T>>`: TypeScript
infers an awaited element in `for await` loops even though a native async
iterator preserves the Promise value.

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
JavaScript during environment cleanup. Class registrations remain live until
their environment ends. Functions created with `env.function` release their Dart
callbacks when JavaScript collects them.

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
