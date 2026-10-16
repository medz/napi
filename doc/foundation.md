# Direct-Wasm foundation

This document describes the existing Wasm development foundation. The
[native and Wasm architecture](architecture.md) defines the current product
direction. JavaScript host dependencies and callable globals remain valid Wasm
implementation choices. This foundation does not implement the native backend.

This implements the bounded foundation in #115, following #107 and #114. It
removes the old implementation, tests, fixtures, benchmarks, examples, and
historical documentation. The repository, Git history, MIT license, development
instructions, package name/version, repository links, and topic metadata remain.
No old compiler/runtime helper or baseline fixture is reused or relocated.

## Compiler boundaries

```text
BindingFrontend -> BindingModule -> validate -> ModulePlan -> emit
                                                        -> SDK adapter -> linker
```

`front_end` defines the analyzer boundary. The foundation starts with handwritten
IR; #116 supplies annotation discovery. Analyzer objects never enter the IR or
runtime. Declaration identity is a library URI and source name; diagnostics retain
original source locations. Dart type semantics are explicit: `SafeIntType` cannot
be inferred from a JavaScript-platform analyzer view that erases int/double.

The IR describes types and parameter presence. Analysis rejects unsupported
categories and duplicate/invalid names. Lowering chooses the export representation
and conversions. Emitters consume that plan for Dart entrypoints, JS host imports,
and TypeScript declarations. `DeclaredType` records structural, opaque, reference,
and shared categories without pretending their conversion engines exist.

The runtime has a compiler-independent operation lease interface for future
resource/callback retention. It implements no ownership, cancellation, or lifetime
engine. No empty feature directories stand in for implementations.

## Export representation

| API | Wasm export kind | Contract |
| --- | --- | --- |
| Generated required scalar function | `function` | externref inputs; fixed arity; not constructible |
| Presence-sensitive function proof | immutable externref `global` | original JS callable; captures actual argument count |
| Class constructor proof | immutable externref `global` | original JS class; supports `new` and private receiver branding |

Native Wasm function parameters cannot recover whether a caller omitted an
argument or explicitly passed `undefined`. Numeric Wasm inputs can coerce JS values
before generated validation. The scalar entry therefore receives raw externrefs;
its host import validates primitive type and numeric policy before conversion to
Dart. Invalid inputs never enter business code or invoke coercion hooks. Missing
and explicit-undefined required scalars both reject, including nullable scalars.
Dart output is also checked for the safe-integer range when using number-represented
ints; Dart int canonicalizes negative zero to zero. #117 adds nullable and
nonnullable `bool`, `String`, `double`, `BigInt`, and fixed bigint-represented
`int` conversions. See [the scalar contract](scalars.md) for precise ranges,
UTF-16 and IEEE-754 behavior.

The handwritten export-kind fixture uses a thin public `module.wasm` whose globals
import JS class/function values from a host dependency. That host calls a separate
Dart `core.wasm`. Node's ESM loader exposes each global's value directly, so the
consumer still writes `import { Counter } from './module.wasm'; new Counter()`.
The real state and mutation execute in a retained Dart class. The JS class keeps a
private receiver brand and rejects forged/cross-runtime receivers.

Presence wrappers capture actual argument count before entering the fixed-arity
Dart ABI. Required opaque omission fails; explicitly supplied `undefined` and
`null` survive unchanged. Optional opaque omission selects its default; supplied
`undefined` survives. Ordinary optional omission and `undefined` both select the
Dart default. Extra arguments are ignored, consistent with the proof's chosen JS
call convention.

These fixtures validate the representation and linking route. They are not an
annotation/class generator, general opaque storage engine, resource policy, or a
claim of leak freedom. Generated optional calls are diagnosed until #118;
generated classes and opaque carriers follow #123 and #125. Those implementations
must add their full ownership, identity, failure, and lifetime contracts.

## Linking and initialization

Dart's core imports its generated host helpers. The host imports the same core
namespace, but does not read or call its exports at module top level. References
are used lazily when a business operation calls a helper, after ESM linking. The
Wasm start section and other non-import sections are preserved. Dart application
`main` is never called; both test entrypoints deliberately throw if invoked.

For constructor-valued exports, the thin public Wasm module depends on a JS host
which in turn imports the core. This fixture uses no public JS facade or manual
instantiation. The compiler-generated loader's compile/instantiate/invokeMain APIs
are not copied into the dependency module.

Repeated imports of one URL share exports and Dart state. Copying the complete
artifact graph to a different directory creates independent module state and
class identity. Adding a query only to the entry URL is not specified as an
isolation mechanism. Missing dependencies fail the import before a usable
namespace is returned. Package root/subpath resolution is verified with a
handwritten npm fixture; production metadata generation remains #134/#135.

## SDK compatibility boundary

Only Dart 3.13.5 stable is accepted. Its internal dart2wasm snapshot, platform
kernel, `--enable-experimental-wasm-interop`, `dart:_wasm`,
`dart:_js_interop_wasm`, and `wasm:import`/`wasm:export` pragmas are experimental
compiler coupling. They are isolated in `sdk_adapter`; this is not a claim that
stable public Dart APIs alone provide direct native exports.

The adapter verifies the compiler version and required SDK files. The linker
validates the recognized generated host layout and supported Wasm import forms.
Unknown versions, loader layouts, and unresolved import modules fail with
compatibility diagnostics before final artifacts are published. JS-string
builtins remain native Wasm imports on the pinned Node version. Generated string
constants and normal compiler host imports become named exports of a dependency.

Generated artifact directories retain the SDK license as `DART_LICENSE`.
Source maps are deliberately disabled for this foundation. The linker preserves
all non-import Wasm sections byte-for-byte; it does not rewrite function/global
indices or reinterpret Dart GC instructions. A thin global-export facade avoids
inserting globals into the compiled Dart module. Supporting a new compiler layout
requires a reviewed adapter change and fresh conformance execution.

## Build and package scope

`buildModule` accepts semantic IR and writes only to a new output directory. It
stages compilation/linking before renaming completed artifacts into place and
cleans temporary files on failure. Publication uses a build-time-only native
no-replace rename: `renameat2(RENAME_NOREPLACE)` on Linux,
`renamex_np(RENAME_EXCL)` on macOS, and the pinned Dart SDK's Windows
`Directory.renameSync` implementation (`MoveFileExW` without replacement). Existing output, including an empty directory or symlink created while
the compiler runs, is rejected without deleting or modifying it. Unsupported
hosts, missing native symbols, and filesystems without exclusive rename fail
closed; there is no check-then-rename fallback. The host FFI is not imported by
generated Dart or shipped in the Wasm artifacts. Linux runs full conformance;
macOS/Windows CI separately exercises the publication primitive, which does not
establish compiler/runtime support on those hosts. This is a conservative first-build boundary; incremental replacement,
package-name validation, package assets/licenses, and consumer metadata assembly
remain the scoped work in #134/#135 and #106.

No release, backwards compatibility with the removed implementation, broader
Node-version matrix, Bun/browser support, native addon ABI, async behavior, or
performance improvement is claimed by this PR.
