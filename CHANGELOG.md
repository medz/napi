## 0.12.0

- Reuse ordinary Dart model typedefs for SDK bool/int/double/String/Uint8List in supported signatures, with preserved nullability and canonical TypeScript types. Add no runtime brands or separate leaf-type exports.
- Analyze conditional imports and exports using the build SDK's Wasm library conditions, matching the branch selected by compilation.
- Identify failing top-level arguments in scalar and byte conversion errors, preserving exception identity when diagnostic formatting fails.
- Reject non-directory output paths before source-package analysis and Wasm compilation, identifying the blocking component and preserving existing files. Recheck the destination before staged installation and retain directory/symlink safeguards.
- Reduce documentation-only CI cost while retaining complete source, native runtime, TypeScript and bundler validation. Keep the native import API, ownership rules, SDK/runtime scope and dependencies.

## 0.11.0

- Add a complete binary-file checksum application: Node file/stdin I/O, one native Wasm call, Dart CRC32/counting and precise input/result record types.
- Verify the shipped application against Node's built-in CRC32, reuse its packed artifact across the Node matrix, and check its real Buffer-based TypeScript consumers.
- Preserve the existing byte ownership, native import API, SDK/runtime scope and zero generated runtime dependencies; no application speedup claim.

## 0.10.0

- Export SDK `Uint8List` and nullable byte fields in flat named records, record batches and Future completions, with precise `Uint8Array` declarations.
- Copy every input byte field before business code or Promise return and every result field into independent storage, including repeated references across fields and rows.
- Report detached or out-of-bounds byte views with precise field paths while preserving unrelated JavaScript exceptions. Keep byte-field helpers out of byte-free modules.
- Verify real Buffer types, native package/subpath/relative imports and external-Wasm bundles; record paired byte/record conversion costs without timing gates.

## 0.9.1

- Reject record aliases named `keyof`, `infer` or `unique` with a source diagnostic before compilation; TypeScript interprets these names as type operators and previously generated invalid declarations.
- Preserve valid record aliases, readonly array inputs, mutable results and ordinary functions or parameters with the same names.

## 0.9.0

- Generate readonly array parameters for scalar Lists and record batches, including nullable containers and elements. Mutable arrays, frozen arrays and `as const` tuples share the existing snapshot semantics.
- Preserve mutable result arrays and Future completion values, public record aliases and precise errors. Keep the valid `ReadonlyArray` record alias without introducing a conflicting global type.
- Reject the record alias `readonly` with a source diagnostic before compilation; TypeScript interprets that name as an operator and previously generated unusable declarations. Functions and parameters named `readonly` remain supported.
- Demonstrate readonly inputs in the request-summary consumer and verify real frozen inputs, independent mutable outputs and strict native-import declarations across the Node matrix.

## 0.8.0

- Add a complete request-summary application: ordinary Dart grouping/counting/safe-integer aggregation, a Node stdin NDJSON command, sample data and a strict TypeScript consumer.
- Preserve exact operation names and UTF-16 sorting, independent results and readable failures with no partial summary output.
- Build/pack/install the actual example once and verify native package/subpath/relative imports and the shipped CLI across the Node matrix. The exported value API and platform support remain unchanged.

## 0.7.0

- Compose record field diagnostic paths only when conversion fails; preserve exact sync/Future errors, snapshots and independent ownership.
- Add focused `records` and `batch` benchmark groups that skip unrelated builds and measurements.
- Retain paired measurements in both run orders: modest batch conversion improvements and smaller record artifacts, without a stable direct-record speedup claim.

## 0.6.0

- Export one List layer of flat named records with independent container, element and field nullability, including Future completion values.
- Generate precise Array/Promise declarations and public record types reachable only through List elements.
- Snapshot complete batches before business code or Promise return; copy every non-null result position into an independent data object and retain exact index/field error paths.
- Reject output List lengths outside the JavaScript Array range before conversion and preserve unsigned Array lengths/indices across the i32 boundary.
- Verify packed batch consumers and external-Wasm application bundles across the Node matrix; measure batch conversion, normalization and aggregation costs.

## 0.5.0

- Export flat named records with mixed scalar fields as independent JavaScript data objects, including nullable records and Future completion values.
- Generate exported TypeScript types for public non-generic record typedefs, including imported aliases and nullable alias definitions.
- Validate required own data fields without calling accessors or reading unknown properties; preserve contextual errors, safe integers, UTF-16, cross-realm inputs, and call-time snapshots.
- Reuse a compiled record consumer across the Node matrix and record conversion/size measurements.

## 0.4.0

- Verify native Wasm consumers on Node 22.19.0, 24.5.0, 24.21.0 and 26.11.1 with scalar, Future and collection regressions and TypeScript declarations.
- Build, pack and install each consumer fixture once; reuse the same artifacts across CI runtimes without repeating Dart compilation.
- Verify an esbuild 0.28.2 Node application bundle with Wasm imports kept external; preserve the direct native import API and zero npm runtime dependencies.
- Document exact tested platforms and the Chrome 155 native instance-import limitation. Browser execution and transformed Wasm bundling remain unsupported.

## 0.3.0

- Export flat Dart Lists and String-keyed Maps with scalar values, nullable containers/elements, and Future completion types.
- Generate exact Array, Record, and Promise declarations from resolved signatures.
- Validate dense own-data Arrays and ordinary object fields without invoking getters; preserve cross-realm values and special Map keys.
- Copy complete input containers before business code runs and independent results on completion; report conversion paths in errors.
- Measure collection conversion costs and emit collection helpers only where needed.
- Preserve original JavaScript errors when hostile stack accessors or prototype traps throw during diagnostic extraction.

## 0.2.0

- Export ordinary Dart `Future<T>` functions as native Wasm functions returning JavaScript `Promise<T>`.
- Generate precise Promise declarations for supported values, nullable results, and `Future<void>`.
- Reject input errors, synchronous throws, async failures, and unsafe results consistently; preserve non-null JavaScript exceptions and expose Dart stack traces. JS null/undefined failures follow SDK exception wrapping.
- Copy byte inputs before awaiting and byte results on completion.
- Safely format Dart exceptions and stack traces that throw during `toString`.
- Add reproducible build, package-size, cold-import, and conversion benchmarks.

## 0.1.0

- Export annotated Dart functions as real Wasm ESM named functions.
- Generate npm entries that point directly to Wasm, with automatic host interop.
- Emit `.d.ts` package declarations and relative `.wasm` TypeScript companions.
- Support booleans, safe integers, doubles, UTF-16 strings, copied bytes, and nullable values.
- Check argument types, preserve readable errors, and copy Buffer/cross-realm bytes.
- Validate signatures and protect output directories with staged replacement.
- Use Dart 3.13.5 experimental Wasm interop and Node's experimental Wasm ESM integration.
