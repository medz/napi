# Roadmap

## 0.1.0 — native Wasm imports

- [#29: Resolve exports and generate TypeScript declarations](https://github.com/medz/napi/issues/29).
- [#30: Generate native Wasm exports and automatic host interop](https://github.com/medz/napi/issues/30).
- [#33: Make native Wasm ESM named imports the consumer API](https://github.com/medz/napi/issues/33).
- [#31: Package, validate, and publish the first version](https://github.com/medz/napi/issues/31).

Acceptance is defined in the issues and [requirements](requirements.md). This release establishes the complete Dart-to-Wasm-import workflow for synchronous functions on Node.

## Next — useful types and reliable platforms

- [#26: Future<T> → Promise<T>](https://github.com/medz/napi/issues/26).
- [#28: Broader tested compiler/runtime support](https://github.com/medz/napi/issues/28), including native browser imports and real bundler consumers.
- [#34: Define typed List and Map export contracts](https://github.com/medz/napi/issues/34) with precise declarations and explicit ownership rules.
- [#35: Establish reproducible performance and package-size baselines](https://github.com/medz/napi/issues/35); optimize measured bottlenecks.
- Improve diagnostics and add complete application examples based on real usage.

Each addition starts with concrete Dart and JavaScript code, explicit value/error/ownership rules, and an acceptance case. Release complete, tested workflows in small increments. Dates and platform support are announced only when verified.

## Separate proposals

[#27: Independent Node-API host compatibility](https://github.com/medz/napi/issues/27) is a separate ABI proposal, not a requirement for native Wasm ESM imports. Classes, JavaScript callbacks, and zero-copy buffers need demand and ownership contracts before scheduling. Native `.node` addons are outside the project goal.
