# Loading and compatibility

## Verified fixture matrix

Linux x64: Dart 3.13.5, Node 24.19.0, Bun 1.4.3 and TypeScript 7.0.2. The same generated private npm fixture is packed, installed in a clean consumer, then executed on both runtimes. This is the early #107 loading experiment, not its full acceptance matrix.

The generated ESM entry imports project-owned bootstrap/error helpers. Bootstrap reads a colocated Wasm asset with `new URL(..., import.meta.url)`, calls the paired SDK loader's `compile` and `instantiate`, and passes a unique registration key to `invokeMain`. Generated Dart uses public `dart:js_interop` / `dart:js_interop_unsafe` and `@JSExport` to register its bridge synchronously. The SDK's `.mjs` and `.wasm` artifacts are never parsed, patched or rewritten.

## Initialization contract

Successful ESM import means initialization is complete; exported functions are immediately callable. Ordinary repeated/concurrent imports of the same module URL use the host's ESM cache and one module instance. The temporary nonenumerable global callback has a fresh key per initialization and is removed in `finally`, including registration failures. It is a handshake, not a security boundary against hostile code in the same JavaScript realm.

Compilation, instantiation and registration failures reject the import. ESM may cache a failed module; retrying the same failed URL is not promised to recover. Independent bootstrap attempts use fresh keys and can recover; fake-loader tests distinguish that property from engine guarantees. Explicit public isolated-instance APIs and the reference isolation conformance matrix belong to #107/#112.

## Packaging limits

Only the fixture package root is exported, with generated `.mjs` and `.d.mts` declarations. Internal assets are not advertised subpaths. Production metadata preservation, rebuild policy, package names, bundler asset emission and complete classes/async packaging are deferred. Bundler-mode TypeScript checking does not prove JavaScript bundler execution.

The 0.14.0 direct `.wasm` import API is historical. New generated ESM is the intended replacement; no direct-Wasm compatibility layer is maintained in this branch. There is no browser distribution, native `.node` backend or claim to Node-API host ABI compatibility (#27).
