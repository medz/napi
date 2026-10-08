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
