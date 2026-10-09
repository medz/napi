# Requirements

## Goal

A Dart author writes ordinary functions and marks exports with `@napi`. One command produces real WebAssembly named exports and TypeScript declarations. Consumers use:

```js
import { add } from './dist/module.wasm';
add(1, 2);
```

The business implementation must execute in Dart Wasm. The consumer must not write glue or call an initialization function. npm package exports must point to the Wasm file. Any necessary JavaScript host helpers are imported automatically by that file.

The project name is `napi`; the primary backend is Wasm ESM integration, not the Node-API C ABI. Native addon output is outside the goal.

## 0.1.0 contract

- One Dart package: `napi`; one annotation; one `napi:build` entrypoint.
- Analyze the resolved entry library and derive bridge and declarations from the same signatures.
- Support synchronous public top-level functions with explicit return types, required positional parameters, and the types documented in the README.
- Preserve nullability, safe integer precision, UTF-16 strings, double special values, and independent byte ownership. Reject unsupported signatures before compilation.
- Use true native Wasm exports and Node's instance-phase ESM integration. Ignore surplus arguments; reject missing or wrong-typed arguments.
- Preserve unrelated Wasm sections while rewriting host imports. Detect unsupported compiler helper layouts instead of generating broken output.
- Generate `module.wasm`, `module.imports.mjs`, `index.d.ts`, `module.d.wasm.ts`, and npm metadata. No npm runtime dependencies or JSON value serialization.
- Resolve package and subpath declarations without special TypeScript options; resolve relative Wasm declarations with `allowArbitraryExtensions`.
- Verify fresh consumers, native function identity, strict types, error recovery, repeated calls, cross-realm bytes, and output-directory safety before release.
- State experimental compiler/runtime status and platform support accurately. Browser and bundler support requires separate real-consumer evidence.

## 0.2.0 contract

- Resolve SDK `Future<T>` return types for both ordinary and `async` functions; generate `Promise<T>` from the same completion type used by the bridge.
- Support the 0.1 value types, nullable completion values, and `Future<void>` resolving `undefined`. Reject Future parameters, nullable/nested Futures, `FutureOr`, streams, callbacks, generators, and `async void` exports before compilation.
- Return a genuine Promise for every Future call; reject argument errors, synchronous throws, asynchronous failures, and result conversion errors with the same error categories as synchronous exports.
- Preserve original non-null JavaScript exception values. JS `null`/`undefined` throws and rejections follow the SDK's Dart-exception wrapping and become readable JavaScript `Error` objects. Expose readable Dart messages and `dartStack`; use a fallback when user-defined error or stack formatting throws, so settlement cannot hang.
- Copy bytes at call time before the first `await`, then copy results at completion. Preserve strict types, safe integers, and UTF-16.
- Reuse compiler microtasks and timers without adding initialization or npm dependencies. Verify native imports, concurrency, timer cancellation, settlement, recovery, ownership, retained memory, and TypeScript consumers on the minimum Node runtime.
- Provide reproducible build, size, cold-import, and call/conversion measurements with environment and variance; keep performance thresholds out of correctness CI.

## 0.3.0 contract

- Resolve actual SDK `List<T>` and `Map<String,T>` signatures with flat bool/int/double/String leaves; preserve nullable containers and leaves. Allow collections as Future completion values. Derive the bridge and precise Array/Record/Promise declarations from the same signature model.
- Validate and copy all inputs before entering business code, also before returning an async Promise. Return new independent containers at synchronous return or Future completion, including empty containers.
- Accept dense own-data Arrays across realms. Reject holes, inherited indices, accessors, typed arrays, and invalid leaves; never invoke property getters. Ignore unrelated named and symbol properties.
- Accept ordinary and null-prototype objects across realms. Read own enumerable string data properties; reject accessors, class instances, custom prototypes, Arrays, Date, and JS Map/Set. Ignore inherited, non-enumerable, and symbol fields.
- Emit null-prototype objects and preserve special keys, UTF-16 keys/values, double special values, and safe integers. Do not promise key order. Null requires nullable signatures; reject undefined. Conversion failures identify parameter/result and index/key; Proxy reflection traps and exceptions follow ordinary JS and the 0.2 error policy.
- Reject raw/aliased/nested collections, unsupported leaves, and non-String or nullable Map keys with source positions before compilation. Preserve the existing direct Uint8List contract.
- Verify native package/subpath/relative imports, precise TypeScript in both resolution modes, sync/Future calls, mutation independence, all scalar/nullability combinations, cross-realm values, malformed properties, recovery, and retained memory.
- Measure 0/1/16/256/4096 element conversions and package-size changes. Omit unused collection helpers from scalar-only packages. Keep one native import API, no JSON serialization, no new runtime dependencies, and no timing gates in correctness CI.

## 0.4.0 contract

- Reuse one compiled, packed and installed scalar/Future/collection artifact per SDK across Node consumers. Keep the full original test suite, format/analyze checks and pub dry run.
- Verify package, subpath and relative native Wasm exports on Node 22.19.0, 24.5.0, 24.21.0 and 26.11.1. Preserve strict types, safe integers, UTF-16, copy ownership, nullable values, error identity, Future settlement, recovery and retained-memory checks.
- Verify TypeScript 7.0.2 NodeNext/Bundler package declarations without extra flags and relative declarations with allowArbitraryExtensions; the missing-flag negative case must still fail as expected.
- Execute a real esbuild 0.28.2 Node application bundle with generated Wasm kept external. Inspect the bundle's imports and run it on the tested Node matrix. Do not substitute automatic Wasm instantiation or re-export glue for native loading.
- Record actual browser instance-phase results with exact versions and correct HTTP MIME types. Keep native browser loading unsupported when the direct named-import probe fails; do not equate source-phase imports or WasmGC with instance-phase loading.
- Add no production dependencies or wrapper APIs, preserve SDK ^3.13.5 and the existing generated engine requirement, and publish only after final-head review/CI and independent hosted-package validation.

## 0.5.0 contract

- Resolve nonempty named-only records with mixed SDK bool/int/double/String fields, nullable leaves and records, and Future completion values. Emit inline object types or public non-generic record typedef exports from the same signature model; retain outer alias names and effective nullability, including imported aliases and non-generic chains.
- Require every declared field, even when nullable, as an own data property. Accept non-enumerable data fields and ordinary/null-prototype inputs across realms. Ignore unknown fields without enumerating or reading them; reject missing/inherited/accessor/undefined fields without invoking getters.
- Snapshot declared descriptors and validate all arguments before business code or Promise return. Emit new null-prototype outputs with exactly the declared mutable own data fields. Preserve the scalar, safe-integer, UTF-16, exception identity, contextual error and Future contracts. Arbitrary Proxy traps are observable reflection operations, not a transaction.
- Diagnose unsupported positional/mixed/empty/nested records, collection/byte fields, record collection elements, generic aliases, conflicting alias names and TypeScript built-in shadowing before compilation. Scalar/collection/Future aliases remain unsupported. Keep type and function value namespaces separate.
- Reuse a fourth compiled/packed/installed fixture across the tested Node matrix, with real native npm/subpath/relative imports and strict TS positive/negative consumers. Measure representative 1/4/16-field conversion and package costs; emit no record helpers for scalar-only modules.
- Preserve one annotation and native import API, zero runtime dependencies and the documented platform limits. Gate publication on the normal final-head review/CI and independent hosted-consumer validation.

## 0.6.0 contract

- Admit one SDK List layer around flat named records, including inline/public non-generic aliases, independent container/element/field nullability, nullable alias definitions, and Future completion values. Export type aliases reachable only through Lists, with existing name/origin diagnostics and accurate Array/Promise declarations.
- Validate dense own-data indices and every declared record field before business code or Promise return. Later-element/argument failure prevents entry. Preserve ignored unknown properties, cross-realm/non-enumerable record inputs, scalar rules, original JS exceptions and single composed index/field error paths.
- Return a new Array and a fresh null-prototype data object for each non-null position. Snapshot array membership and scalar fields at call time; do not preserve repeated-object identity across output positions. Proxy reflection remains observable rather than transactional.
- Reuse existing value/record models and host helpers through direct typed loops. Keep Map record values, nested Lists/record fields, collection aliases, generics, classes and callbacks unsupported; add no schema framework, closure adapter, annotation, loader or runtime dependency.
- Build/pack/install a fifth batch fixture once, reuse it across the Node matrix, and run real external-Wasm batch bundles plus strict TS and negative consumers. Preserve all existing suites, output safety and scalar-only helper footprint.
- Measure 0/1/16/256/4096-record conversions, representative widths, normalization and aggregation against single-record calls and a JS reference. Include per-record allocation/copy costs, raw samples and variance; publication requires normal final-head review/CI, exact-SHA merge and a fresh hosted consumer. Platform support remains unchanged.

## Iteration priorities

After publishing the first complete workflow, prioritize Future-to-Promise support, useful typed data structures, clear diagnostics, compiler/runtime compatibility, reproducible performance and size measurements, and real applications. Define consumer syntax, type and ownership rules, and acceptance cases before implementing each addition.

Classes, callbacks, zero-copy buffers, and scheduling require concrete use cases and explicit lifetime/error contracts. Keep one consumer API and add dependencies only when they materially simplify a necessary task.
