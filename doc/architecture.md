# Native and Wasm architecture

The product is a Dart counterpart to napi-rs: one annotation, one build command,
one export model, and matching JavaScript/TypeScript APIs across native Node-API
and Wasm targets. The current compiler generates
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
automatic runtime supply remain development work; see [native scope](native.md).

## Public contract

Consumers import the package and call its exports. Generated loaders initialize
the selected backend. Classes support `new Counter()`, methods and identity.
Ordinary optional parameters apply Dart defaults for omission or `undefined`;
opaque values preserve explicitly supplied `undefined` where their contract
requires it. Factories or explicit presence parameters are not replacements.

Strict scalar validation, safe integers, bigint, exact UTF-16 strings, nullability,
structural conversion, generic substitutions, opaque identity, resources, shared
views, Futures, callbacks, streams and cancellation remain tracked requirements.
An unsupported feature fails during the build; it must not silently select a
different public contract. Completion requires both target conformance and
documented platform capabilities.

[Collection ownership](collections.md) follows the napi-rs distinction between
converted containers and explicit JS handles. Ordinary Dart List/Map values
produce independent containers. Explicit `JsArray`/`JsMap` scalar handles retain and return
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
platforms and runtime supply remain #144; a `.node` binary alone does not qualify
its Dart runtime or distribution.

The Wasm backend uses Dart WasmGC and the SDK's host imports. napi-rs uses Rust
WASI and emnapi for its Wasm target. We follow its binding and package model;
its binary ABI is not interchangeable with Dart WasmGC. Retain the working
SDK adapter and linker while reducing unnecessary wrappers with measurements.

## Qualifying a native profile

For each new profile, demonstrate a fresh npm consumer loading a real `.node` addon and invoking
ordinary Dart AOT business code. Include a strict scalar function and a retained
Dart class called with `new Counter()`. Record the exact SDK, Node, compiler,
OS/architecture and redistributable files.

Measure cold import, artifact sizes, process memory and scalar/batched calls.
Compare equivalent Wasm and native business work, separating startup from
steady-state cost. Do not infer that native is faster or smaller from its name.

Verify exceptions, UTF-16, integer boundaries, object lifetime, repeated imports,
multiple addon packages, worker creation/termination and process exit. Determine
runtime sharing, per-environment isolation and cleanup, including async
work. A process-global runtime must not be disposed while another environment or
package still uses it. A local scalar probe alone does not satisfy this gate.

## Package and validation policy

[buildPackage](packaging.md) defaults to Wasm and can include both targets.
`target` chooses the root at build time; `/native` and `/wasm` select explicitly.
The root points directly to the chosen backend, and a broken backend fails
without fallback. Both targets share declaration text in separate modules so
runtime-specific brands remain isolated. Automatic platform selection and
qualified runtime supply remain #134/#144; unsupported targets fail explicitly.

Keep native OS/architecture/runtime files with their licenses and exact version
metadata. Keep Wasm and its JS dependencies together. Verify packed installs
outside the checkout, declaration resolution, no manual initialization and
output-directory safety. Node-API compatibility does not by itself establish
Dart runtime compatibility with Bun or other hosts.

## Delivery order

1. Preserve the delivered argument/default, class, ownership and async contracts
   on both targets. Complete the remaining combinations in #119-#133 and
   cross-feature acceptance in #137; no single slice closes the full API roadmap.
2. Extend qualified native profiles and runtime supply in #144. Existing macOS
   arm64 feasibility results are documented in [native builds](native.md). The
   independent Node-API host research in #27 has its own qualification scope; it
   is not a prerequisite for native platform support or runtime distribution.
3. Keep explicit single-/dual-target packages and independent consumers working
   while completing automatic selection (#134), safe rebuilds (#135) and
   migration documentation (#138). Fresh packaging and package-name safety are
   already implemented.
4. Prepare complete user-facing milestones with cumulative changelogs, final
   Codex connector review, CI and fresh published-package verification.

The final PR commit needs the GitHub Codex connector's completed review with no
unresolved findings and required CI before exact-SHA merge. CodeRabbit is not a
gate. Release preparation is separate from feature PRs. Publish at most four
versions per Asia/Shanghai calendar day; this is a ceiling, not a release target.

## References

- [napi-rs native modules](https://napi.rs/docs/deep-dive/native-module)
- [napi-rs Wasm artifacts and runtime](https://napi.rs/docs/concepts/webassembly)
- [Node-API](https://nodejs.org/api/n-api.html)
- [Existing Wasm foundation](foundation.md)
- [Superseded single-Wasm research](single-wasm.md)
