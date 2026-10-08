## 0.1.0

- Export annotated Dart functions as real Wasm ESM named functions.
- Generate npm entries that point directly to Wasm, with automatic host interop.
- Emit `.d.ts` package declarations and relative `.wasm` TypeScript companions.
- Support booleans, safe integers, doubles, UTF-16 strings, copied bytes, and nullable values.
- Check argument types, preserve readable errors, and copy Buffer/cross-realm bytes.
- Validate signatures and protect output directories with staged replacement.
- Use Dart 3.13.5 experimental Wasm interop and Node's experimental Wasm ESM integration.
