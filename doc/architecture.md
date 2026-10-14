# Compiler/runtime foundation

## Ownership boundaries

One Dart package exposes `lib/napi.dart` for authors and `lib/runtime.dart` for generated code. The runtime entry uses public JavaScript interop and targets Dart Wasm; it is not a VM runtime. Portable adapter contracts live below it without interop/compiler imports.

```text
src/api
src/compiler/front_end → ir → analysis → lowering → emit/{dart,js,typescript}
src/runtime             (no compiler, build or analyzer dependency)
src/build               (orchestrates stages, SDK and runtime assets)
assets/runtime          (maintained JavaScript helpers)
```

Only `front_end` uses analyzer Elements and DartTypes. The frontend uses the same SDK's default Wasm library conditions, including conditional imports and exports, instead of the analyzer's host defaults. Analyzer is bounded to the 14.5 patch line (tested at 14.5.0) because its public collection constructor does not expose declared variables; a narrowly scoped implementation import stays inside the frontend. SDK profile parsing fails explicitly if the library specification is unsupported. `FixtureFrontend` implements the frontend boundary by selecting named top-level functions, resolving their actual types, and copying declaration identity, source spans and primitive policies into IR. It does not implement annotation discovery. Analyzer objects never enter IR or plans. Library URI and declaration name identify a source declaration independently of its future public rename. Source offsets/lengths are UTF-16; diagnostic lines/columns are one-based.

IR lists are copied into unmodifiable collections. Validation rejects unsupported policies and public names before lowering. Lowering selects direction-specific conversion operations and the required argument count, plus a synchronous value-only lifetime plan. Plans are separate immutable objects, inspectable without generating code. Emitters specialize their source from these decisions; there is no per-call schema interpreter. TypeScript uses the same policy metadata rather than inferring types from source again.

Module tests enforce import boundaries and reject private Dart SDK imports. Future additions must preserve them; putting an analyzer object in a generically typed field would still violate the architecture even if an import test cannot detect it.

## Executable subset

Required positional primitive parameters and synchronous primitive/void returns need no retained identity or cleanup state. JavaScript checks arguments before crossing public interop; in particular, an unsafe integer cannot be rounded by conversion first. Dart checks integer outputs before converting to a JS number. Void wrappers return JavaScript undefined. Required nonnullable inputs reject both null and undefined; extras follow ordinary JavaScript function behavior and are ignored.

The generated bridge wraps each invocation with `guard`. Conversion and user-code errors become a private envelope; JavaScript maps the error kind to TypeError, RangeError or Error, preserving nonenumerable `dartType` and `dartStack`. Diagnostic formatting is guarded too: a thrown object whose `toString` or `runtimeType` throws receives a static fallback rather than leaking a raw Wasm exception. The envelope never appears in the public signature. There is no guarantee that a throwing Dart function rolls back its own side effects.

The fixed fixture package is created in a fresh owned temporary output directory. Build never deletes prior outputs or edits the source. The SDK compiler owns its `.mjs`/`.wasm` pair; napi copies project runtime helpers alongside them and does not rewrite compiler internals. A locally packed fixture is installed into a new consumer to test asset resolution outside the build directory.

## Shared adapter contracts for later engines

`src/runtime/contracts.dart` defines interfaces only. It deliberately creates no empty engine directories.

| Contract | Obligation | Owning follow-up |
| --- | --- | --- |
| `ArgumentPresence<T>` | Distinguish omitted from supplied values before conversion; host carriers must further distinguish null and undefined | #108–#110 |
| `RuntimeDomain` | One identity token per Wasm instance; no cross-runtime reference reuse | #112 |
| `ValuePath` / `BindingConversionException` | Preserve nested conversion context and explicit failures | #109 |
| `ConversionScope` | Transactional temporary resources; close on success or failure, idempotent cleanup, primary error preserved | #109/#111/#112 |
| `StructuralValueAdapter` | Independent containers, element-specific identity; Map and explicit dictionary remain separate | #109 |
| `OpaqueCarrier` / `OpaqueValueAdapter` | Preserve arbitrary host identity and supplied nullish values in a runtime domain | #110 |
| `BoundInstanceAdapter` | Validate brand/runtime/liveness, preserve live identity, reject foreign/disposed references | #112 |
| `ByteAdapter` / `ByteOwnership` | Distinguish owned snapshots from explicit shared views; unsupported sharing cannot copy silently | #111 |
| `OperationRetention` / `OperationHold` | Acquire before scheduling; release idempotently on every terminal path | #112/#113 |

Adapters throw conversion errors; generated boundary guards translate them. A future caller must close temporary scopes in `finally`, preserving a primary failure if cleanup also fails. Failed structural conversion must release partial allocations. Async scheduling transfers explicit holds; already accepted operations remain valid after disposal while new operations are rejected. Opaque payload round-tripping does not establish concrete Dart generic semantics. Shared-byte capability detection is explicit.

These are the contract decisions needed to allow independent feature implementation, not proof that those engines exist. `unsupportedCapability` always throws for the listed unimplemented capabilities. Real engines will supply and test adapter implementations in their own issues. No owners' external approval or completed feature acceptance is implied by this interface review.

## Tests and evidence

- Compiler unit tests inspect frontend normalization, source-located failures, immutable IR/plans and validation.
- Generator tests inspect specialized emitted source separately from plans.
- Real installed Node/Bun consumers exercise Wasm arithmetic, numeric boundaries, UTF-16, doubles, void and Dart error translation.
- Fake-loader tests exercise registration failure/cleanup deterministically. They are labeled and do not count as real engine failure coverage.
- TypeScript positive cases and `@ts-expect-error` negative cases run under strict NodeNext and Bundler resolution.
- Full conversion/lifetime engines, real nested composition and full packaging remain #108–#114 work.

## Guidance migration

The root AGENTS, README, requirements, platforms, roadmap and CI now describe this architecture. Legacy executable code, tests, build command and benchmark runners are removed. `CHANGELOG.md` and package version remain unchanged for the release-preparation workflow. Original 0.14.0 documentation and benchmark measurements are kept as history, explicitly outside the new runtime's guarantees. No compatibility shim preserves lowercase `@napi`, private SDK rewrites or direct `.wasm` entrypoints.
