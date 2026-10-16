# Single-Wasm artifact contract

The product remains one annotation, one build command, and one export model.
Ordinary Dart business logic and generated bindings execute in Wasm. Consumers
import named functions from `module.wasm`, or an npm entry resolving to that file.
The final package contains one executable artifact: `module.wasm`. TypeScript
declarations, package metadata, assets, and license notices may accompany it.

No distributed JavaScript, JS npm runtime, dynamic JS source evaluation, custom
loader, manual initialization, native addon backend, build_runner, or plugin
framework may supply missing behavior. Node engine-provided Wasm string builtins
are permitted and must be documented. Other Node built-in capabilities require
an explicit import policy and evidence before becoming part of the contract.
Build tools and consumer test programs are separate from distributed artifacts.

## Build path

```text
@NAPI Dart -> frontend / semantic IR -> generated Dart bindings
           -> pinned dart2wasm standalone -> static link and prune
           -> module.wasm + declarations + metadata + licenses
```

Runtime implementations may be separate build inputs. They must be statically
linked into the final Wasm file. The final raw import graph must contain only
documented engine builtins and explicitly approved Node built-in capabilities.
Renaming a dependency, hiding JS in a URL or string, or exporting a JS function
through a Wasm global does not satisfy this contract.

Keep annotation discovery, declaration identity, semantic types, source
diagnostics, constant evaluation, and valid TypeScript generation. Replace
runtime-dependent lowering, host generation, and linking incrementally. Another
repository-wide rewrite is unnecessary.

## Evidence and limits

Dart 3.13.5 standalone exposes experimental embedder imports. Its
[documentation](https://github.com/dart-lang/sdk/blob/3.13.5/pkg/dart2wasm/docs/standalone.md)
describes implementing imports in Wasm and linking modules with `wasm-merge`.
This is a possible build path, not a complete Dart runtime supplied by the SDK.

The initial isolated two-module probe passes on Node 24.19.0 and 26.11.1. It
executes real Dart integer and floating-point operations, integer formatting,
string constants, and UTF-16 runtime operations without distributed JS. It also
contains explicit traps for unsupported runtime imports. It does not establish
single-file packaging, full Dart support, strict scalar conversion, or later
binding features. Production builds must reject unsupported capabilities before
publishing output; a trap placeholder is not a supported implementation.

| Requirement | Boundary to preserve |
| --- | --- |
| Strict scalars | Raw numeric Wasm parameters coerce JS inputs. Passing arithmetic tests does not prove type rejection or safe-integer policy. |
| Ordinary defaults | Omission and explicit undefined both default, so actual argc is unnecessary. Undefined/null recognition and conversions still need proof. |
| Named options | Dart labels can be generated. Plain JS object descriptors, own-property rules, and accessors need a proven host interface. |
| Opaque values | Externref can preserve object identity. That alone supplies neither property operations nor actual argc. |
| Opaque presence | Fixed-arity Wasm calls erase the difference between omission and explicit undefined before function entry. |
| JS construction | Native Wasm function exports cannot be called with new. |
| Async and resources | Promises, callbacks, scheduling, cancellation, shared buffers and disposal each need lifetime and host-capability evidence. |

The argc and constructor limits follow the
[Wasm JS calling interface](https://webassembly.github.io/spec/js-api/index.html#exported-functions).
They must remain explicit unresolved requirements until an approved public
mapping resolves them. Do not silently change options into a serialized string,
replace classes with handles, add presence arguments, or close requirements as
implemented without documenting and validating the changed API contract.

## Delivery order

1. Track the corrected artifact and runtime foundation in #144, #115 and #114.
   Prove static linking with recursive GC types, indices, starts, exceptions,
   export identity, raw import inspection and fresh consumers.
2. Revalidate #117's exact scalar behavior against that artifact. Current scalar
   tests depend on JS host imports and remain regression tests for that path.
3. Resume #118's ordinary defaults using reusable constant evaluation and Dart
   branches. Validate named options independently. Preserve the unresolved opaque
   presence requirement and its relationship to #125.
4. Require capability proofs for #119-#133 before implementing their public
   mapping. Preserve original requirements and explicit blocked conditions in
   issues; absence of a proof is not evidence of impossibility or completion.
5. Assemble and verify packages in #134-#136, validate feature composition in
   #137, and finish consumer documentation and migration work in #138. Keep #106
   package-name safety and #27 runtime compatibility visible in this inventory.

A successful Codex connector PR review must match the final head and have no
unresolved findings. Required CI must pass before exact-SHA merge. Independent
reviews can supplement this gate. Group completed user-facing work into release
preparation PRs, with cumulative changelog and version changes there. Publish no
more than four versions per Asia/Shanghai calendar day and verify every public
milestone with a fresh consumer.

These are acceptance gates. Updating an issue or passing a limited probe does
not complete the project or the corresponding feature.
