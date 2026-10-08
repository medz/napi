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

Annotate public, synchronous, top-level functions in the entry library. Use explicit return types and required positional parameters. Extra arguments are ignored, as with ordinary native Wasm functions; missing arguments arrive as `undefined` and fail type checks.

| Dart | JavaScript / TypeScript | Boundary behavior |
| --- | --- | --- |
| `void` | `void` | Return type only; returns `undefined` |
| `bool` | `boolean` | No coercion |
| `int` | `number` | Input and output must be safe integers |
| `double` | `number` | Preserves NaN, Infinity, and negative zero |
| `String` | `string` | Preserves UTF-16 code units |
| `Uint8List` | `Uint8Array` | Copies in and out; Node `Buffer` and cross-realm arrays accepted |
| `T?` | `T \| null` | Accepts `null`; rejects `undefined` |

Invalid arguments throw `TypeError`; unsafe integers throw `RangeError`. Dart `ArgumentError` and `TypeError` become JavaScript `TypeError`, Dart `RangeError` becomes JavaScript `RangeError`, and other Dart exceptions become JavaScript `Error` with a readable message.

The export name `then` is reserved because dynamic ESM imports treat it as a promise callback. Dart compiler helper names such as `$invokeMain` and `$wasmI16ArrayGet` are also reserved; other `$` names are allowed. Classes, generics, typedef aliases at the boundary, optional/named parameters, futures, streams, and callbacks are not supported in 0.1.0. Ordinary Dart helpers and Wasm-compatible dependencies can be used inside exported functions.

## Status and platforms

**0.1.0 is experimental and targets Node's native Wasm ESM integration.** [Node documents instance-phase Wasm imports](https://nodejs.org/api/esm.html#wasm-instance-phase-imports) as experimental. Synchronous CommonJS `require` is not supported.

The backend uses Dart's experimental Wasm interop and compiler-generated JavaScript helpers. It rewrites the Wasm import section so Node resolves the helpers and built-in string operations through ESM; business logic remains Dart Wasm. It does not implement the Node-API C ABI or produce `.node` addons.

Tested compiler: **Dart 3.13.5**. Other SDK versions allowed by the package constraint may change the experimental helper layout; unsupported layouts fail the build with a diagnostic. The generated Node engine requirement is `^22.19.0 || >=24.5.0`.

Native browser instance imports and bundler compatibility are not supported in this release. A browser's support for WasmGC or source-phase imports alone does not establish support for `import { add } from './module.wasm'`. The [roadmap](doc/roadmap.md) tracks platform validation.

The build checks signatures before compiling, supports Dart workspaces, and refuses to overwrite unrelated output directories. Rebuilds stage a complete replacement on the destination filesystem and restore the old package if installation fails. Run `dart pub get` in the source package or workspace first. Use `dart run napi:build --help` for options.

## Development

```sh
dart pub get
dart format bin lib test example
dart analyze --fatal-infos
dart test
dart pub publish --dry-run
```

Integration tests build a real package and verify native functions through package, subpath, and relative Wasm imports. Set `NAPI_TSC` to TypeScript's `bin/tsc` to include the TypeScript consumer checks; CI supplies it. `test/js/browser.html` probes native browser loading without a fallback loader.

See the [requirements](doc/requirements.md) and [0.1.0 milestone](https://github.com/medz/napi/milestone/1).

MIT licensed. Generated host helpers include the Dart SDK's BSD license notice.
