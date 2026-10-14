# Foundation requirements

This checkout implements #115, not every requirement in the #114 design.

## Implemented

- One `napi` package, separate author API and generated-code runtime entry.
- Analyzer-only frontend resolves explicitly selected typed scalar functions.
- Immutable analyzer-independent identity, source span and type-policy IR.
- Validation and separate immutable direction-specific call/conversion/lifetime plans.
- Specialized Dart, JavaScript and TypeScript generation with public interop.
- Unmodified SDK Wasm loader, top-level-await ESM readiness, per-initialization registration cleanup.
- Safe-number integer checks both ways; primitive type checks and error translation.
- Fresh-output fixture compilation, local npm pack/install and real Node/Bun consumers.
- Source diagnostics, architecture checks, unit/generator tests, runtime assertions and strict TypeScript positive/negative cases.

## Intentionally unsupported

The foundation rejects optional/named/nullable, inferred, generic, async and nonprimitive function signatures. It does not discover annotations or externally selected library members. `@NAPI()` is only the declaration API reserved for #108.

Interfaces for structural snapshots, opaque carriers, bound identities, owned/shared bytes and operation retention are contracts, not implementations. No collection adapter, generic instantiation engine, identity registry, disposal engine, scheduler, callback engine or stream engine is supplied. An unsupported runtime capability raises `UnsupportedError`.

Future contracts preserve these distinctions: ordinary optional undefined means omission/default; explicit opaque supplied undefined and null remain distinct from omission. Maps use JS Map, dictionaries are explicit. Containers are independent snapshots unless sharing is explicit; unsupported sharing fails. Safe-number integers never silently round; bigint requires a future explicit policy.

Production package metadata ownership, invalid-name handling (#106), complete installed-consumer compatibility and migration packaging belong to #107 after the frontend/features. No native Node-API compatibility or browser distribution is claimed.
