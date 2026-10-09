# napi

Write Dart functions. Import them directly from WebAssembly in JavaScript and TypeScript.

```js
import { add } from './dist/module.wasm';

add(20, 22); // 42
```

The imported functions are real Wasm exports. No initialization call or JavaScript entrypoint is required.

## Quick start

Use Dart **3.13.5 or newer** and Node **22.19+ in the 22.x line, or 24.5+**:

```sh
dart pub add napi
```

Write `lib/math.dart`:

```dart
import 'dart:typed_data';
import 'package:napi/napi.dart';

@napi
double add(double a, double b) => a + b;

@napi
String greet(String name) => 'Hello, $name';

@napi
int checksum(Uint8List bytes) {
  var sum = 0;
  for (final byte in bytes) {
    sum = (sum + byte) & 0xff;
  }
  return sum;
}
```

Build:

```sh
dart run napi:build lib/math.dart --name @example/math --out dist --version 0.1.0
```

Then import the generated Wasm file from an ES module:

```js
import { add, greet, checksum } from './dist/module.wasm';

console.log(add(20, 22));                     // 42
console.log(greet('Dart'));                  // Hello, Dart
console.log(checksum(new Uint8Array([1, 2]))); // 3
```

Or install the generated directory as an npm package:

```sh
npm install /absolute/path/to/dist
```

```ts
import { add } from '@example/math';
// Also supported: import { add } from '@example/math/module.wasm';

add(20, 22);
```

Both package entries point to `module.wasm`. The generated package has no npm runtime dependencies. Keep `module.imports.mjs` beside the Wasm file: the Wasm module imports these compiler and value-conversion helpers automatically.

## Async functions

Return a Dart `Future<T>` to export a JavaScript `Promise<T>`. Both `async` functions and ordinary functions returning a Future are supported:

```dart
@napi
Future<int> addLater(int a, int b) async {
  await Future<void>.delayed(const Duration(milliseconds: 1));
  return a + b;
}
```

```ts
import { addLater } from './dist/module.wasm';

const result: number = await addLater(20, 22); // 42
// Generated declaration: addLater(a: number, b: number): Promise<number>
```

Every call to a Future export returns a genuine Promise. Invalid arguments, synchronous throws, asynchronous failures, and invalid results reject it. `Future<void>` resolves to `undefined`; `Future<T?>` can resolve to `null`. Errors retain the categories below; Dart failures also expose a `dartStack` string. Original JavaScript exception objects and non-null primitive reasons retain their identity. The Dart SDK wraps JavaScript `throw null`, `throw undefined`, and Promise rejection with either value as Dart exceptions; napi reports these as readable JavaScript `Error` objects. Error or stack formatters that throw use a fallback message so rejection can still finish. Failures while reading a JavaScript error's stack cannot replace that error.

Byte inputs are copied during the call, before its first `await`; byte results are copied when the Future completes. Mutating or detaching the caller's input after the call cannot change the Dart snapshot. Futures use the Dart SDK's microtasks and timers; they do not imply execution on another thread or support for `dart:io` or isolates.

## Lists and maps

Export flat collections of `bool`, `int`, `double`, or `String`:

```dart
@napi
List<int> doubleAll(List<int> values) => [for (final value in values) value * 2];

@napi
Map<String, String> labels(Map<String, String> values) => {...values};
```

```ts
import { doubleAll, labels } from './dist/module.wasm';

const numbers: number[] = doubleAll([1, 2]); // [2, 4]
const names: Record<string, string> = labels({ greeting: 'hello' });
```

Containers and elements can be nullable: `List<int?>?` becomes
`Array<number | null> | null`, and `Map<String,String?>?` becomes
`Record<string,string | null> | null`. Future completion values follow the same
rules, such as `Future<List<int>>` becoming `Promise<number[]>`.

Inputs are fully validated and copied before business code runs, including
before returning a Promise. Outputs are new containers at return or Future
completion. Empty containers are independent too. Values use the scalar rules
below; `undefined` is rejected, including in nullable elements. Failures identify
the parameter or result, with the index or key once available.

Lists accept dense Arrays, including cross-realm Arrays. Every index must be an
own data property: holes, inherited indices, and index accessors are rejected
without invoking getters. Extra named and symbol properties are ignored.
Typed arrays continue to use `Uint8List`; they are not accepted as Lists.

Maps accept ordinary objects, including cross-realm objects, and null-prototype
objects. Only own enumerable string data properties are read; accessors are
rejected without invoking getters. Inherited, non-enumerable, and symbol
properties are ignored. Class instances, custom prototypes, Arrays, Date, and
JavaScript Map/Set are rejected. Outputs have a null prototype and retain keys
such as `__proto__`, `constructor`, and `then`; use `Object.hasOwn` rather than
calling methods on the returned object. Key order is not an API guarantee.
Proxy reflection traps still execute as ordinary JavaScript operations; thrown
exceptions follow the existing error policy.

Nested collections, byte-array elements, non-String or nullable Map keys,
raw List/Map types, and collection aliases are rejected before compilation.

## Data objects

Use a named record for fields with different scalar types. A public non-generic
typedef also becomes an exported TypeScript type:

```dart
typedef User = ({String name, int age, bool? active});

@napi
User normalize(User user) => (
  name: user.name.trim(), age: user.age, active: user.active,
);

@napi
Future<User?> normalizeLater(User? user) async =>
    user == null ? null : normalize(user);
```

```ts
import { normalize, normalizeLater } from './dist/module.wasm';
import type { User } from './dist/module.wasm';

const user: User = normalize({ name: ' Dart ', age: 20, active: null });
const later: User | null = await normalizeLater(user);
```

See [example/users.dart](example/users.dart) for the complete Dart source.
Inline record annotations produce inline object types; imported public aliases,
non-generic alias chains, and nullable record typedef definitions retain their
outer type names. Unused aliases are not exported. These are type-only exports,
with no JavaScript constructor or runtime schema.

Fields must be `bool`, `int`, `double`, or `String`, independently nullable.
All declared fields are required: `active: null` is valid, but missing `active`
or `active: undefined` is rejected. Inputs must be ordinary or null-prototype
objects, including cross-realm objects. Declared fields must be own data
properties; non-enumerable data fields are accepted, inherited fields and
accessors are rejected without calling getters. Unknown properties are ignored
without enumerating or reading them. TypeScript is structural and cannot express
all these descriptor/prototype checks.

Declared descriptors are snapshotted and all inputs validated before business
code runs or a Promise returns. Outputs are fresh null-prototype objects with
exactly the declared mutable data fields. Mutating input or output cannot change
another snapshot. Proxy reflection traps still execute; the snapshot is not an
atomic transaction across arbitrary traps. Conversion errors include the field
path, for example `parameter user["age"]`.

Positional, mixed, empty, nested, and generic records, collection/byte fields,
record collection elements, and class wrappers are unsupported. Scalar,
collection, and Future aliases remain unsupported. Type aliases with conflicting
public names or names that shadow generated TypeScript built-ins fail before
compilation. Dart itself prohibits private and Object-member record field names;
use Maps for arbitrary keys such as `__proto__`.

## TypeScript

Package imports resolve `index.d.ts` through `exports.types` with either `NodeNext` or `Bundler` module resolution.

For a relative import such as `./dist/module.wasm`, napi also generates `module.d.wasm.ts`. Enable TypeScript's [`allowArbitraryExtensions`](https://www.typescriptlang.org/tsconfig/allowArbitraryExtensions.html):

```json
{
  "compilerOptions": {
    "strict": true,
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "allowArbitraryExtensions": true
  }
}
```

The declarations contain the actual exported signatures; no wildcard `.wasm` declaration is needed.

## Supported exports

Annotate public top-level functions in the entry library. Use explicit return types and required positional parameters. Extra arguments are ignored, as with ordinary native Wasm functions; missing arguments arrive as `undefined` and fail type checks.

| Dart | JavaScript / TypeScript | Boundary behavior |
| --- | --- | --- |
| `void` | `void` | Return type only; returns `undefined` |
| `bool` | `boolean` | No coercion |
| `int` | `number` | Input and output must be safe integers |
| `double` | `number` | Preserves NaN, Infinity, and negative zero |
| `String` | `string` | Preserves UTF-16 code units |
| `Uint8List` | `Uint8Array` | Copies in and out; Node `Buffer` and cross-realm arrays accepted |
| `List<T>` | `T[]` | Flat scalar elements; independent input/output Arrays |
| `Map<String,T>` | `Record<string,T>` | Flat scalar values; output has a null prototype |
| Named record / record typedef | Object shape / exported type | Required flat scalar fields; independent null-prototype output |
| `T?` | `T \| null` | Accepts `null`; rejects `undefined` |
| `Future<T>` | `Promise<T>` | Return type only; completion uses the same value rules |

Invalid arguments throw `TypeError`; unsafe integers throw `RangeError`. Dart `ArgumentError` and `TypeError` become JavaScript `TypeError`, Dart `RangeError` becomes JavaScript `RangeError`, and other Dart exceptions become JavaScript `Error` with a readable message.

The export name `then` is reserved because dynamic ESM imports treat it as a promise callback; a scalar record field named `then` is allowed. Dart compiler helper names such as `$invokeMain` and `$wasmI16ArrayGet` are also reserved; other `$` names are allowed. Classes, generics, non-record type aliases, optional/named parameters, generators, streams, and callbacks are not supported. Future parameters, nullable Futures, `FutureOr`, nested Futures, and `async void` exports are also rejected. Ordinary Dart helpers and Wasm-compatible dependencies can be used inside exported functions.

## Status and platforms

**0.5.0 is experimental and targets Node's native Wasm ESM integration.** [Node documents instance-phase Wasm imports](https://nodejs.org/api/esm.html#wasm-instance-phase-imports) as experimental. Synchronous CommonJS `require` is not supported.

The backend uses Dart's experimental Wasm interop and compiler-generated JavaScript helpers. It rewrites the Wasm import section so Node resolves the helpers, string constants, and built-in string operations through ESM; business logic remains Dart Wasm. It does not implement the Node-API C ABI or produce `.node` addons.

Tested compiler: **Dart 3.13.5**. The consumer matrix covers **Node 22.19.0, 24.5.0, 24.21.0 and 26.11.1**, including native imports, strict value and ownership checks, Future settlement and TypeScript 7.0.2 declarations. Other SDK versions allowed by the package constraint may change the experimental helper layout; unsupported layouts fail the build with a diagnostic. The generated Node engine requirement is `^22.19.0 || >=24.5.0`.

An **esbuild 0.28.2 Node application bundle** is tested with the generated Wasm package kept external. Node still loads the original Wasm and its companion host module. Native browser instance imports and bundler transformations of Wasm are unsupported; Chrome 155.0.8059.27 rejected the direct import even with HTTP 200 and the correct Wasm MIME type. A browser's support for WasmGC or source-phase imports alone does not establish support for `import { add } from './module.wasm'`. See [tested platforms and the bundler example](doc/platforms.md).

The build checks signatures before compiling, supports Dart workspaces, and refuses to overwrite unrelated output directories. Rebuilds stage a complete replacement on the destination filesystem and restore the old package if installation fails. Run `dart pub get` in the source package or workspace first. Use `dart run napi:build --help` for options.

## Development

```sh
dart pub get
dart format bin lib test example benchmark
dart analyze --fatal-infos
dart test
dart pub publish --dry-run
```

Integration tests build a real package and verify native functions through package, subpath, and relative Wasm imports. Set `NAPI_TSC` to TypeScript's `bin/tsc` to include the TypeScript consumer checks; CI supplies it. `test/js/browser.html` probes native browser loading without a fallback loader.

CI compiles, packs and installs the four runtime fixtures once with `dart run tool/runtime_fixtures.dart`, then sets `NAPI_RUNTIME_FIXTURES` to that output for the full test suite and reuses the same artifacts on other Node versions. The tool requires a new or empty output directory. Rebuild fixtures after changing the generator or fixture source; this environment variable is for development tests, not consumer initialization.

See the [requirements](doc/requirements.md), [0.5.0 milestone](https://github.com/medz/napi/milestone/5), and [performance measurements](doc/performance.md).

MIT licensed. Generated host helpers include the Dart SDK's BSD license notice.
