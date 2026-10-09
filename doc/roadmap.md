# Roadmap

Develop through small issues and independently reviewed PRs, then combine related
work into complete user-facing milestones. Bump versions and publish through a
release-preparation PR, rather than publishing every merged change. Documentation,
CI, tests, benchmarks, examples and non-urgent fixes normally join the next
milestone; concrete urgent user failures may justify a separate patch.

## 0.1.0 — released: native Wasm imports

- [#29: Resolve exports and generate TypeScript declarations](https://github.com/medz/napi/issues/29).
- [#30: Generate native Wasm exports and automatic host interop](https://github.com/medz/napi/issues/30).
- [#33: Make native Wasm ESM named imports the consumer API](https://github.com/medz/napi/issues/33).
- [#31: Package, validate, and publish the first version](https://github.com/medz/napi/issues/31).

Acceptance is defined in the issues and [requirements](requirements.md). This release establishes the complete Dart-to-Wasm-import workflow for synchronous functions on Node.

## 0.2.0 — released: async functions and measured costs

- [#26: Future<T> → Promise<T>](https://github.com/medz/napi/issues/26).
- [#35: Establish reproducible performance and package-size baselines](https://github.com/medz/napi/issues/35); optimize measured bottlenecks.

Acceptance includes native Wasm functions returning real Promises, strict declarations, consistent errors, call-time byte snapshots, and the [0.2.0 requirements](requirements.md#020-contract).

## 0.3.0 — released: typed collections

- [#34: Add typed List and Map exports](https://github.com/medz/napi/issues/34).

Acceptance covers flat scalar collections, nullable containers and values,
Future completion types, strict own-data property validation, independent
ownership, precise declarations, real Node consumers, and measured conversion
and package-size costs. See the [0.3.0 requirements](requirements.md#030-contract).

## 0.4.0 — released: verified runtime consumers

- [#28: Broader tested compiler/runtime support](https://github.com/medz/napi/issues/28).

Acceptance covers the scalar, Future and collection workflows on Node 22.19.0,
24.5.0, 24.21.0 and 26.11.1, accurate declarations, one compilation per fixture,
and a real esbuild Node application bundle with external Wasm. The browser
instance-phase probe remains a documented limitation. See [tested platforms](platforms.md).

## 0.5.0 — released: typed data objects

- [#39: Named records and exported record typedefs](https://github.com/medz/napi/issues/39).

Acceptance covers required mixed scalar fields, own-data descriptor validation,
nullable records and Future completions, call-time snapshots, independent output
objects, imported public type aliases, precise TypeScript consumers, and measured
conversion/size costs. See the [0.5.0 requirements](requirements.md#050-contract).

## 0.6.0 — released: batch data objects

- [#41: Lists of named records](https://github.com/medz/napi/issues/41).

Acceptance covers ordered heterogeneous batches with independent nullability,
complete call-time snapshots, independent result objects, accurate public types,
index/field diagnostics, real native imports and external-Wasm bundles, and
measured normalization/aggregation costs. See the [0.6.0 requirements](requirements.md#060-contract).

## 0.7.0 — released: measured record conversion

- [#43: Reduce measured record conversion costs and focus benchmark runs](https://github.com/medz/napi/issues/43).

Acceptance preserves the complete value/error/ownership contract, measures the
same compiled fixtures before and after a minimal change in both run orders,
and retains raw samples, JS controls and size observations. See the
[0.7.0 requirements](requirements.md#070-contract) and [measurements](performance.md#record-conversion-optimization-070).

## 0.8.0 — released: runnable request-summary application

- [#45: Ship a complete Dart-to-Node application](https://github.com/medz/napi/issues/45).

Acceptance covers a real stdin NDJSON command with all aggregation in Dart
Wasm, deterministic summaries, safe integer totals, readable errors without
partial output, strict types and one packed artifact reused across the Node
matrix. See the [application](../example/requests/README.md) and
[0.8.0 requirements](requirements.md#080-contract).

## 0.9.0 — released: readonly array inputs

- [#47: Accept readonly array inputs in TypeScript declarations](https://github.com/medz/napi/issues/47).

Acceptance covers mutable/readonly/frozen/`as const` List inputs, scalar and
record element/container nullability, precise input types and mutable sync/Future
results. The native snapshot behavior and valid public record aliases remain
unchanged. See the [0.9.0 requirements](requirements.md#090-contract).

## 0.9.1 — released: type alias diagnostics

- [#49: Diagnose TypeScript operator record aliases before compilation](https://github.com/medz/napi/issues/49).

Acceptance covers source diagnostics for `keyof`, `infer` and `unique` record
aliases in scalar, List and nullable Future signatures. Valid aliases and
ordinary functions or parameters with these names remain supported. See the
[0.9.1 requirements](requirements.md#091-contract).

## 0.10.0 — released: byte fields in data objects

- [#51: Support Uint8List fields in named records](https://github.com/medz/napi/issues/51).

Acceptance covers one native call that transforms packet metadata and owned
binary content, nullable byte fields and existing record/List/Future composition.
Verify independent byte copies, exact field diagnostics, native imports and
types across the Node matrix, helper isolation and measured copy costs. See the
[0.10.0 requirements](requirements.md#0100-contract).

## 0.11.0 — released: runnable binary-file application

- [#53: Ship a complete binary-file checksum application](https://github.com/medz/napi/issues/53).

Acceptance covers file/stdin input, one native Wasm call carrying metadata and
bytes, Dart CRC32/counting and a typed scalar record result. Reuse the existing
boundary and one packed artifact across the Node matrix; verify application
results against Node's built-in CRC32 without a speedup claim or new core API.
See the [0.11.0 requirements](requirements.md#0110-contract).

## 0.12.0 — released: build diagnostics and model reuse

- [#70: Prepare the complete upgrade milestone](https://github.com/medz/napi/issues/70).
- [#57: Reject non-directory output paths before compilation](https://github.com/medz/napi/issues/57).
- [#64: Identify top-level arguments in conversion errors](https://github.com/medz/napi/issues/64).
- [#66: Match export analysis to the Wasm compilation environment](https://github.com/medz/napi/issues/66).
- [#68: Accept transparent SDK leaf typedefs](https://github.com/medz/napi/issues/68).

Acceptance covers clear preflight errors for existing output files and file
ancestors, preserved contents, precise argument errors, correct conditional
import selection and ordinary Dart model typedefs using the existing native
value/ownership boundary. Verify complete direct-Wasm and packed npm workflows
with accurate TS declarations. See the [milestone contract](requirements.md#0120-contract).

[#61: Reduce documentation-only CI cost](https://github.com/medz/napi/issues/61)
keeps light documentation checks separate from the complete source/runtime
validation needed by these changes.

The output-path fix is included in 0.12.0. The unpublished `v0.11.1` tag and
frozen evidence are retained. The public baseline is
[0.12.0](https://pub.dev/packages/napi/versions/0.12.0), verified with a fresh
ordinary-constraint consumer before the
[GitHub Release](https://github.com/medz/napi/releases/tag/v0.12.0) was announced.
Quota recovery does not trigger publication.

## Unreleased development

- [#75: Read checksum input four bytes at a time](https://github.com/medz/napi/issues/75), with recorded performance and artifact costs.
- [#77: Document the verified Webpack external-Wasm route](https://github.com/medz/napi/issues/77), including the current Dart WasmGC parser limitation.
- [#79: Dictionaries of flat named records](https://github.com/medz/napi/issues/79), including direct operation lookup in the request-summary application.

These development units accumulate toward a later complete upgrade. See the
[dictionary contract](requirements.md#record-dictionaries-unreleased-development);
merging a unit does not change package versions or trigger publication.

## Next — compiler compatibility and real applications

- Validate new stable Dart SDK releases before expanding the tested compiler table; preserve clear diagnostics for unsupported helper layouts.
- Improve diagnostics and add complete application examples based on real usage.
- Revisit browser native instance imports when runtime support changes. Wasm bundler transformations are a separate route and require real execution evidence.

Each addition starts with concrete Dart and JavaScript code, explicit value/error/ownership rules, and an acceptance case. Review and merge in small increments; publish the accumulated work when a complete, tested milestone is ready. Dates and platform support are announced only when verified.

## Separate proposals

[#27: Independent Node-API host compatibility](https://github.com/medz/napi/issues/27) is a separate ABI proposal, not a requirement for native Wasm ESM imports. Classes, JavaScript callbacks, and zero-copy buffers need demand and ownership contracts before scheduling. Native `.node` addons are outside the project goal.
