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

## 0.7.0 contract

- Compose a record field error suffix only on conversion failure. Preserve exact parameter/result/index/field paths and error categories for sync/Future calls, including unsafe integers and escaped field names.
- Preserve all 0.6 value types, complete snapshots, independent ownership, native exports and declarations. Add no runtime dependency, host API or wrapper layer; retain scalar-only helper isolation.
- Provide `records`, `batch` and default `all` benchmark groups. Focused groups build and preflight only their required fixtures; batch single-record controls must still validate the scalar record implementation.
- Compare frozen before/after native artifacts using the same harness, inputs and counts in both run orders. Retain all samples, controls, variance, artifact hashes and size observations. Claim only demonstrated improvements; correctness CI has no timing threshold.
- Require the full regression/runtime/TypeScript/bundle matrix, retained-memory controls, final-head Codex review and CI, exact-SHA merge and independent hosted-consumer verification before publication is considered complete. Platform support remains unchanged.

## 0.8.0 contract

- Ship one complete request-summary example with a single annotated Dart function, input/output record aliases, a Node stdin NDJSON command, sample data, a strict TypeScript consumer and runnable root commands. Reuse the current native Wasm API without a loader, framework or new production dependency.
- Keep all grouping, counting, duration aggregation and deterministic UTF-16 operation sorting in Dart. Preserve exact names, empty input and independent results; require nonnegative safe durations and check each operation's safe integer total before adding.
- Parse the complete batch before one native call, ignore blank lines/accept CRLF and write one JSON array only on success. Malformed JSON, boundary validation or domain errors must be readable, return nonzero and publish no partial summary. Node reports native import failures and experimental warnings.
- Verify direct business tests and the real shipped CLI, native package/subpath/relative function identity, required alias/signature types and positive/negative TypeScript consumers on all four Node versions. Build/pack/install the actual example once; preserve all existing regressions and external-Wasm bundle checks.
- Gate release on final-head review/CI, exact-SHA merge and independent hosted-package validation including the complete application. This example expands no exported value support and makes no application speedup claim.

## 0.9.0 contract

- Render List parameters as readonly TypeScript arrays so mutable arrays, readonly arrays, frozen arrays and `as const` tuples are accepted. Preserve scalar/record types, required fields, public alias identity and independent element/container nullability; wrong element types and unsupported values remain rejected.
- Keep result arrays mutable in synchronous and Future completion declarations. Readonly input declarations describe the caller's array; Dart still receives its own normal mutable List snapshot and outputs retain independent ownership.
- Use array keyword syntax without a new global constructor. A public named-record alias called `ReadonlyArray` must compile, run and retain accurate parameter/result types. Reject the invalid TypeScript record alias `readonly` with a source diagnostic before compilation, while preserving valid function and parameter names.
- Demonstrate the corrected API in the request-summary TypeScript consumer. Verify strict npm root/subpath and relative Wasm imports in NodeNext/Bundler, plus real frozen scalar and record inputs, unchanged callers and independently mutable outputs across all four Nodes using reused fixtures.
- Preserve existing value/error/platform/SDK constraints, regressions and external-Wasm bundle checks. Add no runtime conversion branch, loader, framework or dependency; release requires final-head review/CI, exact-SHA merge and a fresh hosted consumer with artifact/source verification.

## 0.9.1 contract

- Reject public named-record aliases called `keyof`, `infer` or `unique` before Wasm compilation, using the existing source diagnostic path. Cover scalar parameters, List results and nullable Future results with the alias name and exact source location.
- Preserve legal record aliases, readonly inputs, mutable results, independent nullability and ordinary functions or parameters named `readonly`, `keyof`, `infer` or `unique`. Keep one signature model and add no runtime branch, parser, wrapper or dependency.
- Require the complete regression/runtime/TypeScript/bundle matrix, final-head review and CI, exact-SHA merge and a fresh hosted consumer. Verify the published CLI rejects all three aliases in each signature shape before compilation, and a packed legal alias artifact retains real native imports and precise declarations across all four Nodes.

## 0.10.0 contract

- Admit SDK `Uint8List` and `Uint8List?` fields in existing flat inline/public named records, including supported aliases, nullable records, Lists of records and Future completions. Use the existing `Uint8Array` rendering with required fields, independent nullability, readonly List inputs and mutable outputs.
- Preserve own-data descriptors, ignored unknown properties, ordinary/null-prototype cross-realm objects and original reflection-trap exceptions. Copy genuine Uint8Array/Buffer views at call time with correct offsets and lengths before business code or Promise return. Wrong values and detached buffers must identify the parameter/index/field path with a readable TypeError.
- Enrich only TypeError from the actual owned byte copy. Keep kind checks and reflection outside that catch; propagate unrelated JS and RangeError failures unchanged. Copies own independent storage after validation; Proxy traps, fields and concurrent shared-buffer writes do not form an atomic snapshot. Inherit the top-level shared/resizable buffer policy.
- Return an independent Uint8Array for each non-null field and result row, even when input or Dart output references repeat. Verify caller mutation/transfer after Future calls, business input mutation, retained results, later-field/row rejection before business entry, nulls, empty payloads and error recovery.
- Generate byte read/write paths only for actual byte fields; preserve byte-free scalar/record/List/Map helper isolation. Keep nested records, collection fields, `List<Uint8List>`, Map byte values and byte type aliases unsupported. Add no model, loader, schema framework, borrowed-buffer API or production dependency.
- Reuse record/batch fixtures across all four Nodes for real package/subpath/relative native imports, strict NodeNext/Bundler positive/negative consumers and external-Wasm bundles. Compare record echo with the existing top-level byte echo at 32/1024/65536 bytes; record raw samples and artifact costs without a speedup promise or timing CI gate.
- Require final-head substantive Codex review, all valid findings fixed, complete CI, exact-SHA merge and a fresh hosted consumer of the full metadata-and-binary workflow. Verify public source/archive/packed artifacts; keep SDK ^3.13.5 and tested platform limits.

## 0.11.0 contract

- Ship a complete file-checksum example: one annotated Dart function accepts `FileInput = ({String name, Uint8List bytes})` and returns `FileChecksum = ({String name, int byteCount, int crc32})`. Node handles file/stdin I/O and JSON output; Dart counts bytes and computes CRC32. Reuse the existing native import and byte-record boundary without a new core API or production dependency.
- Use reflected polynomial `0xedb88320`, initial/final xor `0xffffffff` and one lazily initialized 256-entry table. Preserve exact names and inputs; return an unsigned CRC in `0..4294967295`. The nine ASCII bytes `123456789`, without a newline, produce byteCount 9 and crc32 3421780262. JSON property order is not part of the contract.
- Read stdin by default or for explicit `-`; otherwise read the exact file argument. Excess arguments and file errors produce exit 1, readable stderr and no JSON result. Keep native import failures as Node startup errors. Ship the Dart source, CLI, sample, precise TypeScript consumer and runnable instructions.
- Verify direct business vectors and compare real Wasm binary/view results with built-in `node:zlib.crc32`. Build/pack/install the actual example once and reuse it on the four tested Nodes for native npm root/subpath/relative identity and file/stdin smoke. Check additional filesystem and CLI error cases once on the minimum Node; verify npm and relative types in both resolution modes with actual Node types. Preserve existing regressions, missing-option controls and external-Wasm bundles.
- Require final-head substantive review and CI, exact-SHA merge and independent hosted-package/source/artifact acceptance. Keep SDK `^3.13.5` and platform limits. This is a teaching application with whole-file memory, the normal input copy and a linear byte scan; Node already has CRC32, and no replacement, speedup, streaming or authentication capability is claimed.

## 0.11.1 contract

This unpublished output-path candidate is included in the 0.12.0 milestone.
Its existing tag and frozen evidence are retained.

- Reject an output path that names an existing non-directory component before source-package analysis or Wasm compilation. Identify the blocking component, preserve its contents and create no staged output.
- Cover both the output file itself and missing descendants beneath a file with real CLI regressions. Retain valid missing/empty/generated directories, directory-ancestor resolution and existing symbolic-link safeguards; recheck the destination before installation.
- Preserve the native Wasm value, declaration and runtime contracts without a new dependency or API. Release only after final-head Codex review, CI, exact-SHA merge and a fresh hosted consumer.

## 0.12.0 contract

- Ship one complete upgrade from 0.11.0: reusable Dart model typedefs, compiler-matched conditional signatures, precise top-level argument errors and early output-path diagnostics. Concentrate versions/changelog in the release-preparation PR for #70; do not publish individual development PRs.
- Analyze conditional imports/exports with the selected SDK's Wasm library conditions, matching actual compilation while preserving diagnostics at the selected source. Do not infer runtime support for dart:io/isolates or experimental ffi from this selection.
- Identify invalid scalar and byte parameters without changing safe-integer/nullable/Future behavior or original exception identity when diagnostic formatting throws. Reject output files/file ancestors before compilation, preserve contents and recheck before installation.
- Accept non-generic aliases and chains resolving to SDK bool/int/double/String/Uint8List in existing supported positions: direct values, Future completion values, scalar List/Map leaves, non-null String Map keys and named-record fields. Preserve analyzer-resolved effective nullability and SDK type provenance.
- Expand leaf aliases into the existing TS primitive/Uint8Array types. Preserve outer public record names and their naming/conflict rules; private or same-named leaf aliases emit no separate TS binding. Add no brands, runtime tags, dependencies or value model.
- Preserve existing value/error rules, safe integers, UTF-16, real Promises, precise paths, call-time snapshots, independent objects and byte ownership. Generated conversion paths remain the existing paths for each underlying type.
- Reject generic alias chains and aliases for collection/Future/void/function/class types. Preserve unsupported combinations such as List<Uint8List>, nullable Map keys, Map record values and nested structures. Locate invalid imported record fields at their declarations.
- Verify imported/prefixed/re-exported aliases, nullable chains, precise positive/negative TS consumers, native package/subpath/relative imports and both complete applications. Build each of the existing seven fixture groups once and reuse artifacts across Node 22.19.0/24.5.0/24.21.0/26.11.1, with Dart 3.13.5, TypeScript 7.0.2 NodeNext/Bundler and esbuild 0.28.2 external-Wasm checks.
- Require independent final-SHA review, complete CI, zero-warning pub dry-run and exact-SHA merge. Verify package/generator metadata and main/tag source identity before publication. Validate the real public package with a new ordinary-constraint consumer and empty pub cache, freeze expectations before execution and independently inspect actual source/archive/compiled/packed artifacts and logs before announcing the GitHub Release. Preserve the unpublished v0.11.1 tag; quota recovery does not trigger publication.

## 0.13.0 contract

[#79](https://github.com/medz/napi/issues/79) extends the existing value model
with one `Map<String, flat named record>` layer. Earlier version contracts above
describe the published versions, including their former Map-record restriction.

- Support inline/public non-generic record aliases, including nullable alias
  chains and SDK leaf aliases. Container, value and field nullability remain
  independent; Future completion values generate precise Promise/Record types.
- Reuse Map descriptor snapshots and record field conversion. Validate and copy
  all arguments before business code or Promise return. Read only own enumerable
  string map properties; require own data record fields without invoking getters.
- Preserve exact UTF-16 keys and existing scalar/byte ownership and error rules.
  Return fresh null-prototype dictionaries and record values with independent byte
  storage per occurrence. Include key/field paths once; output iterator/cast errors
  use a key only after it is available, never a previous entry's key.
- Add no host API, dependency, loader or value model. Nested structures,
  collection aliases, nullable/non-String keys and class wrappers remain excluded.
  Scalar-only, byte-free and List-only helper isolation must remain intact.
- Verify native package/subpath/relative consumers, strict NodeNext/Bundler types,
  external-Wasm bundles, sync/Future snapshots, descriptors, unsafe integers,
  retained byte storage, malformed output maps and recovery across the existing
  Node matrix. Build and pack each fixture once for matrix reuse.
- Demonstrate operation lookup through `summarizeByOperation` while retaining
  the sorted request-summary CLI. Include the checked four-byte checksum example
  and record snapshot optimization while preserving all value/error/ownership
  rules. Retain paired raw samples, precise artifact hashes and bounded performance
  conclusions; verify prototype/descriptor regressions without timing gates.
- Keep Dart 3.13.5, the existing four Node runtimes, accurate NodeNext/Bundler
  declarations and three esbuild external-Wasm bundles. The separately verified
  Webpack external-Wasm route does not establish transformed-Wasm or browser support.
- Concentrate pub and generator version 0.13.0, cumulative changelog and upgrade
  instructions in [#85](https://github.com/medz/napi/issues/85). Require independent
  final-SHA review, full CI and zero-warning pub dry-run before exact-SHA merge.
  Verify main/tag source identity, then the public package with a frozen ordinary
  `napi: ^0.13.0` dependency, empty pub cache and official archive/cache/tag equality.
  Build and pack eight fixtures once, reuse native/application/type consumers on
  the four runtimes, and independently inspect actual logs and assets before the
  GitHub Release announcement. Preserve prior tags and unrelated work.

## 0.14.0 contract

[#103](https://github.com/medz/napi/issues/103) combines binary Lists, TypeScript
API documentation and ordinary-package compatibility in one planned upgrade.
Earlier contracts describe the former restrictions of their published versions.

- Support one SDK `List<Uint8List>` layer, including supported transparent byte
  leaf aliases, independent container/element nullability and Future completion
  values. Generate readonly input Arrays, mutable results and precise Promise
  types. Map byte values, nested collections and collection aliases remain excluded.
- Snapshot Array membership and copy every non-null byte input before business
  code or Promise return. Every output occurrence owns separate storage, including
  repeated references. Preserve Buffer, offset/cross-realm/shared/resizable view
  rules, index paths, error identity and recovery. Reject undefined, holes,
  inherited/accessor indices and invalid byte views without calling getters;
  reflection traps and concurrent shared writes are not an atomic transaction.
- Emit JSDoc for annotated functions and reachable public record typedefs in
  both declaration files. Use each outer alias's own comment, including imported,
  re-exported and part declarations. Preserve Markdown and literal Dartdoc
  references/directives; escape terminators, omit empty/unused comments and do
  not add runtime schema or separate leaf-alias bindings.
- Give Dart `_` parameters unique TypeScript bindings without colliding with
  existing parameter names or reserved-word fallbacks. Retain resolved positional
  types and native input validation. Explicitly declare Dart 3.13 for generated
  bridge helpers independently of the source package's default language version;
  preserve business source, pubspec and package configuration.
- Reduce measured host List snapshot construction costs while retaining ordered
  own descriptor reads and independent own data slots. Preserve inherited-setter,
  iterator, species, Proxy/error and helper-isolation behavior. Keep raw before/
  after samples, hashes and run orders, including the approximately 3ns empty
  synchronous-call tradeoff; claim no general async-byte, startup or application
  speedup. See the [recorded comparison](performance.md#host-list-snapshots).
- Preserve one native Wasm import API, zero generated runtime dependencies,
  SDK `^3.13.5` and the four tested Node runtimes. Require the final release tree's
  format/analyze/tests, eight runtime fixtures, strict NodeNext/Bundler types and
  three esbuild external-Wasm applications; reuse each artifact across the matrix.
- Concentrate pub/generator version 0.14.0, cumulative changelog and upgrade
  instructions in the release-preparation PR. Require independent final-SHA
  review of source/generated/packed assets, full CI, zero-warning pub dry-run and
  exact-SHA merge before publishing the reviewed tag. Read completed exact-tree
  CI evidence without repeating baselines or downloading the same artifacts again.
- Separately resolve the public `napi: ^0.14.0` package from an empty cache and
  verify official archive/cache/tag source equivalence. Compile the frozen new
  consumer once from that resolved package, pack/install once and reuse it on
  all four Nodes. Verify native package/subpath/relative imports, strict types,
  byte snapshots/copies/errors, both declaration comments and ordinary language/
  wildcard cases. Reuse no prepublication artifact as public-package proof;
  broaden builds only for a concrete unresolved failure. Independently inspect
  actual assets/logs before announcing the GitHub Release. Preserve prior tags
  and unrelated work; quota recovery is not a publication trigger.

## Iteration priorities

After publishing the first complete workflow, prioritize Future-to-Promise support, useful typed data structures, clear diagnostics, compiler/runtime compatibility, reproducible performance and size measurements, and real applications. Define consumer syntax, type and ownership rules, and acceptance cases before implementing each addition.

Classes, callbacks, zero-copy buffers, and scheduling require concrete use cases and explicit lifetime/error contracts. Keep one consumer API and add dependencies only when they materially simplify a necessary task.
