# Native and Wasm architecture

The product is a Dart counterpart to napi-rs: one annotation, one build command,
one export model, and matching JavaScript/TypeScript APIs across native Node-API
and Wasm targets. This is the target architecture. The current compiler generates
Wasm required positional scalar functions; native addons and complete class
bindings remain development work.

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

The native candidate is a small Node-API bridge loading a pinned Dart AOT
runtime and generated Dart entrypoints. The exact Dart embedding API and artifact
layout require validation in #144. A `.node` binary alone does not prove that the
Dart runtime and snapshot can be distributed or cleaned up correctly.

The Wasm backend uses Dart WasmGC and the SDK's host imports. napi-rs uses Rust
WASI and emnapi for its Wasm target. We follow its binding and package model;
its binary ABI is not interchangeable with Dart WasmGC. Retain the working
SDK adapter and linker while reducing unnecessary wrappers with measurements.

## Native feasibility gate

Demonstrate a fresh npm consumer loading a real `.node` addon and invoking
ordinary Dart AOT business code. Include a strict scalar function and a retained
Dart class called with `new Counter()`. Record the exact SDK, Node, compiler,
OS/architecture and redistributable files.

Measure cold import, artifact sizes, process memory and scalar/batched calls.
Compare equivalent Wasm and native business work, separating startup from
steady-state cost. Do not infer that native is faster or smaller from its name.

Verify exceptions, UTF-16, integer boundaries, object lifetime, repeated imports,
multiple addon packages, worker creation/termination and process exit. Determine
runtime sharing, per-environment isolation and cleanup before extending to async
work. A process-global runtime must not be disposed while another environment or
package still uses it. A local scalar probe alone does not satisfy this gate.

## Package and validation policy

The package should load a matching native artifact and expose a selectable Wasm
target through the same API. Implement and test the selection policy in #134;
tests must force each backend so fallback cannot hide a broken artifact. Only
claim automatic fallback where backend capabilities and loading behavior are
verified. Unsupported targets fail with an actionable diagnostic.

Keep native OS/architecture/runtime files with their licenses and exact version
metadata. Keep Wasm and its JS dependencies together. Verify packed installs
outside the checkout, declaration resolution, no manual initialization and
output-directory safety. Node-API compatibility does not by itself establish
Dart runtime compatibility with Bun or other hosts.

## Delivery order

1. Correct the roadmap and record native feasibility results in #144, with
   shared architecture in #114 and the existing foundation in #115.
2. Reuse the valid optional/default work for #118 and finish generated class
   behavior in #123. Build the native scalar/class slice against the same
   consumer assertions before expanding native features.
3. Complete conversion, ownership and async requirements in #119-#133, including
   cross-feature composition in #137. Keep platform limitations explicit.
4. Finish packaging, atomic rebuilds, independent consumers and migration docs
   in #134-#138. Include package-name safety (#106) and runtime qualification (#27).
5. Prepare complete user-facing milestones with cumulative changelogs, final
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
