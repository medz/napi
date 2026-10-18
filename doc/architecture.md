# Native and Wasm architecture

napi compiles Dart declarations into native Node-API addons or Dart Wasm
packages. Both targets share one `@NAPI()` export model, conversion rules and
TypeScript declarations. JavaScript consumers import the generated package and
call its functions or construct its classes normally.

## Public contract

Generated loaders initialize the selected backend on import. Business logic
runs in Dart AOT or Dart Wasm. Classes support `new Counter()`, methods,
inheritance and object identity.

Ordinary optional parameters apply Dart defaults for omission or `undefined`.
Opaque generic payloads preserve explicitly supplied `undefined`; omitting a
required payload is an error. See [arguments](arguments.md) and
[generic payloads](opaque.md).

Both targets use the same scalar precision, UTF-16, structural conversion and
ownership rules. Supported reference classes, concrete aliases, resources,
Futures, callbacks, streams and cancellation expose matching APIs. Unsupported
signatures fail during the build. The individual feature guides describe the
supported combinations.

[Collection ownership](collections.md) distinguishes converted containers from
explicit handles. Ordinary Dart List/Map values produce independent containers.
`JsArray`/`JsMap` handles retain the original JavaScript Array/Map. Exported Dart
classes and methods expose shared Dart-owned state. Arbitrary Dart containers
are not automatically live JavaScript views.

Native opaque values and callbacks retain JavaScript references while Dart
holds them. A cycle spanning both heaps requires the author to clear a stored
value, unregister a callback or use the owner's cleanup method. GC and
teardown release references without running business cleanup. Wasm can collect
some cross-heap cycles automatically; portable code still breaks them explicitly.

## Compilation boundaries

```text
@NAPI Dart / external bindings
             |
     frontend + semantic IR
             |
     validation + conversions + TypeScript
             |
       target-specific lowering
        /                    \
Node-API binding          Wasm binding + JS interop
        |                    |
Dart AOT + runtime        Dart Wasm + runtime helpers
        \                    /
       npm entry + target artifacts
```

The frontend resolves annotations or external selections, declaration identity,
types and defaults. Shared analysis and lowering determine conversion and
TypeScript semantics. Backend-specific code owns calling conventions, JS
references, scheduling and teardown. Analyzer objects do not enter runtime code.

The [native backend](native.md) loads a pinned Dart AOT runtime through a
Node-API bridge. The package builder automatically downloads and caches its
precompiled runtime, or accepts an explicit local bundle. Application builds
compile only Dart code. Runtime maintainers use the separate
[native build tools](../native/README.md).

The [Wasm backend](foundation.md) uses Dart WasmGC and generated JavaScript host
imports. Constructor and presence-sensitive exports use a thin public Wasm
module over the compiled Dart core. Consumers do not instantiate these modules
manually.

napi-rs provides the binding and packaging reference. Its Rust Wasm target uses
WASI/emnapi; that binary ABI is not interchangeable with Dart WasmGC. Dart's
compiler and embedding interfaces are experimental and pinned to the supported
SDK version.

## Package layout and compatibility

[buildPackage](packaging.md) defaults to Wasm and can include both targets.
`target` chooses the package root at build time; `/native` and `/wasm` select
explicitly. Importing both backends creates separate Dart state. References and
resources belong to the backend that created them.

Both targets use identical declaration text in separate modules so their class
brands remain distinct. Native packages include the bridge, runtime, business
AOT and licenses. Wasm packages include the public Wasm entry and all generated
dependencies.

The native target currently supports macOS arm64. Automatic platform selection,
other native platforms and implicit fallback to Wasm are unsupported. The
builder's automatic runtime download supplies the supported native profile;
it does not select a different backend at import time. See
[supported toolchains](../README.md#verify).

## References

- [napi-rs native modules](https://napi.rs/docs/deep-dive/native-module)
- [napi-rs WebAssembly](https://napi.rs/docs/concepts/webassembly)
- [Node-API](https://nodejs.org/api/n-api.html)
