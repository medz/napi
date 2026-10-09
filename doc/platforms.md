# Tested platforms

The primary backend uses native Wasm ESM instance imports. All supported Node
consumers import actual Wasm functions through the package root, the
`package/module.wasm` subpath, or a relative `.wasm` path. The generated package
includes `module.imports.mjs`, which the Wasm module imports automatically.

## Compiler and Node matrix

| Dart compiler | Node | Native Wasm imports | Coverage |
| --- | --- | --- | --- |
| 3.13.5 | 22.19.0 | Experimental, no Wasm flag | Full Dart suite and runtime consumers |
| 3.13.5 | 24.5.0 | Experimental, no Wasm flag | Same scalar, Future, collection, record and batch artifacts |
| 3.13.5 | 24.21.0 | Experimental, no Wasm flag | Same scalar, Future, collection, record and batch artifacts |
| 3.13.5 | 26.11.1 | Experimental, no Wasm flag | Same scalar, Future, collection, record and batch artifacts |

Runtime coverage includes safe integers, UTF-16, double special values, nullable
values, byte/collection/record/batch ownership, cross-realm values, original JavaScript
errors, strict property validation, Future settlement and recovery, and retained
memory after garbage collection. All rows also verify TypeScript 7.0.2 package
and relative Wasm declarations in NodeNext and Bundler resolution modes.

[Node 24.5.0 removed the Wasm module flag](https://nodejs.org/en/blog/release/v24.5.0).
The generated engine constraint remains `^22.19.0 || >=24.5.0`; the table records
exact tested versions, not a claim that every allowed future runtime or compiler
has been verified. Node's [instance-phase integration](https://nodejs.org/api/esm.html#wasm-instance-phase-imports)
and Dart's Wasm interop remain experimental. Synchronous CommonJS `require` is
unsupported.

The SDK constraint remains `^3.13.5`. Only 3.13.5 has been verified in this matrix;
other allowed SDKs can change the compiler helper layout. Unsupported layouts
produce a build diagnostic. Preview SDKs are not a release support claim.

## Bundling a Node application

esbuild **0.28.2** can bundle the application while keeping the generated Wasm
package external. Node then performs native Wasm ESM loading. Build the README's
Quick start module as `@example/math`, then write `app.ts`:

```ts
// app.ts
import { add, checksum } from '@example/math';

console.log(add(20, 22));
console.log(checksum(new Uint8Array([1, 2])));
```

```sh
npm install /absolute/path/to/dist
npx --yes esbuild@0.28.2 app.ts --bundle --platform=node --format=esm \
  --external:@example/math '--external:*.wasm' --outfile=app.mjs
node app.mjs
```

Keep `app.mjs`, the installed generated package, and its original Wasm/host
files together when deploying. The runtime test application also exercises
Lists, Maps, record batches and Futures, including package/subpath/relative imports, snapshots,
special keys, nullable values and errors on the Node versions above. The metafile verifies that all three
user imports remain external ESM imports and that only application source is
bundled. The same bundle runs across the runtime matrix.

[esbuild external imports](https://esbuild.github.io/api/#external) remain runtime
imports. This is support for a Node application bundle with external Wasm;
Wasm transformation, browser bundling and generated instantiation glue have not
been validated. No esbuild dependency is added to generated packages.
esbuild erases TypeScript annotations; run TypeScript separately to check types.

## Browser native imports

On **2026-10-09**, Chrome **155.0.8059.27** on macOS 27.0.1 failed direct native
instance-phase imports for both a minimal `answer()` module and a module with
List/Map/Future exports. Each JavaScript entry statically imported named functions
from `.wasm`; an outer dynamic import recorded loading errors without adding an
initialization API or fallback.

The HTTP requests returned **200**, JavaScript used `text/javascript`, and Wasm
used **`application/wasm`**. Chrome rejected the Wasm module with its strict module
MIME check before evaluating the Dart host helpers. These results came from the
Codex in-app Chromium browser using its default settings; they are not a test of
browser flags, other Chrome releases or other engines.

Native browser instance loading remains unsupported. WasmGC availability,
source-phase imports and successful TypeScript Bundler resolution do not prove
that `import { add } from './module.wasm'` executes in a browser. Future browser
or bundler support needs a separate real consumer and an accurate description
of its loading path.

## Reproducing the runtime checks

Run the ordinary test suite as documented in the README. To reuse a fresh set
of packed consumers across runtimes, build them once:

```sh
dart run tool/runtime_fixtures.dart
NAPI_RUNTIME_FIXTURES="$PWD/.dart_tool/runtime-fixtures" dart test
```

The tool only accepts a new or empty output directory. Its consumer directories
contain installed npm packages and relative `dist` links, so package and relative
imports reach the same Wasm instance. CI archives these artifacts and its pinned
JavaScript tools in one tarball, preserving the links, then runs the additional
Node jobs without installing Dart or recompiling the fixtures. Other build and
output-safety tests still run in the full Dart suite. Never reuse these fixtures
after changing the generator or fixture sources.

TypeScript checks require `NAPI_TSC` pointing to TypeScript's `bin/tsc`, as in the
README. Relative `.wasm` declarations need `allowArbitraryExtensions`; package
imports do not. This setting validates declarations and does not provide a
runtime loader.
