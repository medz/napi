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
