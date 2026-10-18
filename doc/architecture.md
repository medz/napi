# Native and Wasm architecture

The product is a Dart counterpart to napi-rs: one annotation, one build command,
one export model, and matching JavaScript/TypeScript APIs across native Node-API
and Wasm targets. The compiler generates
Wasm scalar and structural functions with positional and named parameters,
reference classes with direct class values and weak wrapper identity, external selections, and fresh npm
assembly. The experimental macOS arm64 native
target generates scalar, structural, reference-class, resource and Future AOT bindings against a
precompiled runtime bundle. Future exports share the [Promise boundary](futures.md),
including [resource operation leases](resources.md).
Both targets also generate [generic payload storage](opaque.md) with matching
generic TypeScript declarations and actual omission detection.
[Concrete class aliases](concrete-generics.md) select real Dart instantiations
with resolved member substitutions and invariant selected JavaScript handles.
Both also generate [retained and async callbacks](callbacks.md), with shared
scalar/List/record conversions, weak adapter identity and exact JS failures.
Both generate [Stream async iterators](streams.md) with a shared subscription
kernel and the existing backend delivery transports. Explicit
[AbortSignal inputs](cancellation.md) share cooperative cancellation and retained
token ownership, reusing the native owner queue without an ABI change.
Both generate [independent byte snapshots](binary.md) for `Uint8List` and
`ByteBuffer`, including existing structural, Future and Stream conversions.
Explicit [shared byte views](shared-bytes.md) preserve host storage with current
window checks, weak adapter identity and bulk operations. Other native targets and
automatic runtime supply are not yet supported; see [native scope](native.md).

## Public contract

Consumers import the package and call its exports. Generated loaders initialize
the selected backend. Classes support `new Counter()`, methods and identity.
Ordinary optional parameters apply Dart defaults for omission or `undefined`;
opaque values preserve explicitly supplied `undefined` where their contract
requires it. Factories or explicit presence parameters are not replacements.

Strict scalar validation, safe integers, bigint, exact UTF-16 strings, nullability,
structural conversion, generic substitutions, opaque identity, resources, shared
views, Futures, callbacks, streams and cancellation follow the same public model
on both targets. Unsupported signatures fail during the build; they do not
silently select a different public contract.

[Collection ownership](collections.md) follows the napi-rs distinction between
converted containers and explicit JS handles. Ordinary Dart List/Map values
produce independent containers. Explicit `JsArray`/`JsMap` handles with scalar or
direct opaque payloads retain and return
the original Array/Map; exported Dart classes and methods expose shared Dart
state. Arbitrary Dart-owned live collection adapters are outside this scope.
Existing Dart Map and Dictionary representations are unchanged.

Persistent opaque values use explicit reference ownership, following napi-rs's
model. An unreachable acyclic native carrier releases its JS reference; a Dart
root keeps that reference alive. A cycle spanning a JS payload and its Dart
owner requires the author to clear the stored value, unregister the callback,
or use the owner's cleanup method. Neither a weak payload reference nor a
mandatory disposal method on every ordinary class replaces this contract.
GC and environment teardown release references without running business cleanup.
Wasm may collect such cycles automatically, but portable code must break them.
Generated opaque bindings use the native owned-value primitive and direct
traced externrefs on Wasm. Function-typed inputs use typed callback adapters whose
lifetime follows Dart references; a generic payload containing a JS function
remains an unchanged value and is never invoked by that adapter.

Generated JavaScript is allowed for loading, conversion and runtime interop.
Business logic stays in Dart. A single Wasm file is an optimization candidate,
not a correctness requirement. Existing direct `.wasm` named imports remain a
supported foundation path; the unified npm entry may be JavaScript.

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

Reuse declaration discovery, source diagnostics, semantic types, constant
evaluation and TypeScript generation. Keep Node-API and Wasm calling conventions,
native handles, JS references, scheduling and teardown in their respective
backends. Extract shared code only when both backends need it; no plugin
framework or generic runtime abstraction is required.

The native implementation uses a small Node-API bridge loading a pinned Dart AOT
runtime and generated Dart entrypoints. Its embedding API, asset layout and
lifecycle are qualified for the documented macOS arm64 profile. Additional
platforms and automatic runtime supply are not yet supported. A `.node` binary
still requires a compatible Dart runtime and its distribution assets.

The Wasm backend uses Dart WasmGC and the SDK's host imports. napi-rs uses Rust
WASI and emnapi for its Wasm target. We follow its binding and package model;
its binary ABI is not interchangeable with Dart WasmGC. Retain the working
SDK adapter and linker while reducing unnecessary wrappers with measurements.

## Package and validation policy

[buildPackage](packaging.md) defaults to Wasm and can include both targets.
`target` chooses the root at build time; `/native` and `/wasm` select explicitly.
The root points directly to the chosen backend, and a broken backend fails
without fallback. Both targets share declaration text in separate modules so
runtime-specific brands remain isolated. Automatic platform selection and
automatic runtime supply are not implemented; unsupported targets fail explicitly.

Keep native OS/architecture/runtime files with their licenses and exact version
metadata. Keep Wasm and its JS dependencies together. Packages initialize on
import and retain their generated declaration and asset paths after installation.
Node-API compatibility does not by itself establish
Dart runtime compatibility with Bun or other hosts.

## References

- [napi-rs native modules](https://napi.rs/docs/deep-dive/native-module)
- [napi-rs Wasm artifacts and runtime](https://napi.rs/docs/concepts/webassembly)
- [Node-API](https://nodejs.org/api/n-api.html)
- [Existing Wasm foundation](foundation.md)
