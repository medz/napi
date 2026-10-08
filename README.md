# napi

Write Dart functions. Ship a Wasm package that JavaScript and TypeScript can import.

`napi` generates a Wasm Node-API bridge, Node/browser ESM entrypoints, and TypeScript declarations. It does not generate native `.node` addons. The generated npm package has no runtime dependencies.

## Quick start

Use Dart **3.13.5 or newer**:

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

Build the package:

```sh
dart run napi:build lib/math.dart --name @example/math --out dist --version 0.1.0
```

Install the generated directory in a JavaScript project:

```sh
npm install /absolute/path/to/dist
```

```ts
import { add, greet, checksum } from '@example/math';

console.log(add(20, 22));                    // 42
console.log(greet('Dart'));                 // Hello, Dart
console.log(checksum(new Uint8Array([1, 2]))); // 3
```

Wasm initializes during the ESM import using top-level await. Calls after initialization are synchronous. Generated `.d.ts` declarations resolve through the package's `exports` and `types` fields. Synchronous CommonJS `require` is not supported.

## Supported exports

Annotate public, synchronous, top-level functions in the entry library. Parameters must be required and positional. Each call must supply exactly the declared number of arguments.

| Dart | JavaScript / TypeScript | Boundary behavior |
| --- | --- | --- |
| `void` | `void` | Return type only; returns `undefined` |
| `bool` | `boolean` | No coercion |
| `int` | `number` | Input and output must be safe integers |
| `double` | `number` | Preserves NaN, Infinity, and negative zero |
| `String` | `string` | Copies UTF-16 code units |
| `Uint8List` | `Uint8Array` | Copies in and out; Node `Buffer` accepted |
| `T?` | `T \| null` | Accepts `null`; rejects `undefined` |

Invalid arguments throw `TypeError`; unsafe integers throw `RangeError`; Dart exceptions become JavaScript `Error`. Classes, generics, typedef aliases at the boundary, optional/named parameters, futures, streams, and callbacks are not supported in 0.1.0. Ordinary Dart helpers and Wasm-compatible dependencies can be used inside exported functions.

## Runtime and compiler

This first release is experimental. The backend uses Dart's experimental Wasm interop to emit real `env.napi_*` C ABI imports and raw Wasm registration/callback exports. Its small JavaScript host implements the synchronous Node-API subset needed by the generated bridge. It is not a complete Node-API implementation; independent emnapi-host compatibility is a [planned feature](https://github.com/medz/napi/issues/27).

Dart WasmGC and a separate linear memory coexist in the module. Temporary conversion memory is reused by call scopes, and host handles are released on both successful and failed calls. Byte results are independent copies, not borrowed views into Wasm memory.

Tested compiler: **Dart 3.13.5**. Node packages require **Node 22+**; browsers need the WebAssembly features required by Dart's Wasm compiler, including WasmGC, and ESM with top-level await. Browser builds use `fetch` to load the adjacent `.wasm` asset. Serve the generated files over HTTP and retain the compiler's `.mjs` assets. Bundlers must preserve the Wasm URL and support top-level await.

The build checks signatures before compiling and refuses to overwrite unrelated output directories. Run `dart pub get` in the source package first. Use `dart run napi:build --help` for options.

## Development

```sh
dart pub get
dart format bin lib test example
dart analyze --fatal-infos
dart test
dart pub publish --dry-run
```

Integration tests build and import a real package with Node. Set `NAPI_TSC` to TypeScript's `bin/tsc` to run the strict TypeScript consumer checks; CI supplies it. Browser verification is described in `test/js/browser.html`.

See the [roadmap](docs/roadmap.md), [requirements](docs/requirements.md), and [0.1.0 milestone](https://github.com/medz/napi/milestone/1).

MIT licensed.
