# Direct-Wasm foundation

This document describes the Wasm export representation, initialization and SDK
boundary used by the compiler. The
[native and Wasm architecture](architecture.md) describes both backends;
[native builds](native.md) have a separate ABI and runtime bundle. Generated
JavaScript dependencies and callable Wasm globals preserve the public API.

## Compiler boundaries

```text
BindingFrontend -> BindingModule -> validate -> ModulePlan -> emit
                                                        -> SDK adapter -> linker
```

`front_end` defines the analyzer boundary. Source annotations and external
selections produce the shared semantic IR. Analyzer objects never enter the IR or
runtime. Declaration identity is a library URI and source name; diagnostics retain
original source locations. Dart type semantics are explicit: `SafeIntType` cannot
be inferred from a JavaScript-platform analyzer view that erases int/double.

The IR describes types and parameter presence. Analysis rejects unsupported
categories and duplicate/invalid names. Lowering chooses the export representation
and conversions. Emitters consume that plan for Dart entrypoints, JS host imports,
and TypeScript declarations. `DeclaredType` records supported structural, opaque,
reference and shared categories; validation rejects unsupported combinations.

The shared runtime implements operation leases, resource state, Stream and
cancellation coordination. Backend-specific code owns JS references, scheduling
and teardown. See [resources](resources.md), [callbacks](callbacks.md),
[streams](streams.md) and [cancellation](cancellation.md) for their contracts.

## Export representation

| API | Wasm export kind | Contract |
| --- | --- | --- |
| Generated required scalar function | `function` | externref inputs; fixed arity; not constructible |
| Generated optional/named scalar function | immutable externref `global` | captures argc and own named-property presence |
| Generated class constructor | immutable externref `global` | original JS class; supports `new` and private receiver branding |

Native Wasm function parameters cannot recover whether a caller omitted an
argument or explicitly passed `undefined`. Numeric Wasm inputs can coerce JS values
before generated validation. The scalar entry therefore receives raw externrefs;
its host import validates primitive type and numeric policy before conversion to
Dart. Invalid inputs never enter business code or invoke coercion hooks. Missing
and explicit-undefined required scalars both reject, including nullable scalars.
Dart output is also checked for the safe-integer range when using number-represented
ints; Dart int canonicalizes negative zero to zero. The compiler supports nullable
and nonnullable `bool`, `String`, `double`, `BigInt`, and fixed bigint-represented
`int` conversions. See [the scalar contract](scalars.md) for precise ranges,
UTF-16 and IEEE-754 behavior.

Constructor and presence-sensitive exports use a thin public `module.wasm` whose globals
import JS class/function values from a host dependency. That host calls a separate
Dart `core.wasm`. Node's ESM loader exposes each global's value directly, so the
consumer still writes `import { Counter } from './module.wasm'; new Counter()`.
The real state and mutation execute in a retained Dart class. The JS class keeps a
private receiver brand and rejects forged/cross-runtime receivers.

Presence wrappers capture actual argument count before entering the fixed-arity
Dart ABI. Required opaque omission fails; explicitly supplied `undefined` and
`null` survive unchanged. Optional opaque omission selects its default; supplied
`undefined` survives. Ordinary optional omission and `undefined` both select the
Dart default. Extra arguments are ignored.

See [arguments](arguments.md), [classes](classes.md) and [opaque ownership](opaque.md)
for the generated APIs and lifetime rules.

## Linking and initialization

Dart's core imports its generated host helpers. The host imports the same core
namespace, but does not read or call its exports at module top level. References
are used lazily when a business operation calls a helper, after ESM linking. The
Wasm start section and other non-import sections are preserved. Dart application
`main` is never called.

For constructor-valued exports, the thin public Wasm module depends on a JS host
which in turn imports the core. Direct Wasm imports require no manual
instantiation. The compiler-generated loader's compile/instantiate/invokeMain APIs
are not copied into the dependency module.

Repeated imports of one URL share exports and Dart state. Copying the complete
artifact graph to a different directory creates independent module state and
class identity. Adding a query only to the entry URL is not specified as an
isolation mechanism. Missing dependencies fail the import before a usable
namespace is returned. [Package assembly](packaging.md) generates metadata and
root/subpath exports, including explicit dual-target packages and managed rebuilds.

## SDK compatibility boundary

Only Dart 3.13.5 stable is accepted. Its internal dart2wasm snapshot, platform
kernel, `--enable-experimental-wasm-interop`, `dart:_wasm`,
`dart:_js_interop_wasm`, and `wasm:import`/`wasm:export` pragmas are experimental
compiler coupling. The `sdk_adapter` isolates these version-specific interfaces.

The adapter verifies the compiler version and required SDK files. The linker
validates the recognized generated host layout and supported Wasm import forms.
Unknown versions, loader layouts, and unresolved import modules fail with
compatibility diagnostics before final artifacts are published. JS-string
builtins remain native Wasm imports on the pinned Node version. Generated string
constants and normal compiler host imports become named exports of a dependency.

Generated artifact directories retain the SDK license as `DART_LICENSE`.
Source maps are disabled. The linker preserves
all non-import Wasm sections byte-for-byte; it does not rewrite function/global
indices or reinterpret Dart GC instructions. A thin global-export facade avoids
inserting globals into the compiled Dart module. Supporting a new compiler layout
requires an adapter compatible with that layout.

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
generated Dart or shipped in the Wasm artifacts. Publication primitive support
does not establish compiler/runtime support on the same host. Package-name validation,
explicit assets/licenses and consumer metadata assembly are implemented by
[buildPackage](packaging.md). Managed npm packages can be atomically rebuilt on
local macOS APFS, preserving author content and metadata. Raw module replacement,
legacy output adoption and replacement on other platforms are not supported.

The compiler is tested on the Node versions in [the test guide](testing.md).
Bun/browser support and additional native profiles remain unqualified.
