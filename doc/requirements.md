# Requirements

## Goal

A Dart author writes ordinary functions and marks exports with `@napi`. One command produces a publishable ESM package that JavaScript and TypeScript consumers can import without writing glue or calling an initialization function.

The business implementation must execute in Dart Wasm. The boundary must use actual Node-API C ABI imports and registration/callback exports. No native addon output is required.

## 0.1.0 contract

- One Dart package: `napi`; one annotation; one `napi:build` entrypoint.
- Analyze the resolved entry library and derive bridge, JavaScript exports, and TypeScript declarations from the same signatures.
- Support synchronous public top-level functions, exact required positional arguments, and the types documented in the README.
- Preserve nullability, safe integer precision, UTF-16 strings, double special values, and byte ownership. Reject unsupported signatures early.
- Initialize once through ESM top-level await. Node and browser share the same generated Wasm and runtime.
- Generated npm packages have no runtime dependencies. Do not serialize values through JSON.
- Reuse temporary linear memory and release JavaScript handles on every callback, including exceptions.
- Verify fresh consumers, strict TypeScript declarations, browser loading, and repeated calls before release.
- Keep compiler interop experimental status and the supported Node-API subset visible.

## Deferred

Native `.node` builds, synchronous CommonJS, automatic npm publishing, a build plugin ecosystem, zero-copy borrowed buffers, worker scheduling, asynchronous functions, class wrappers, and callbacks are separate features. Add them only with a concrete use case and a defined lifetime/error contract.
