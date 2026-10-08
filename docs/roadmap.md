# Roadmap

## 0.1.0 — synchronous Wasm packages

- [#29: Resolve exports and generate TypeScript declarations](https://github.com/medz/napi/issues/29).
- [#30: Generate the Wasm Node-API bridge and scoped runtime](https://github.com/medz/napi/issues/30).
- [#31: Package, validate, and publish the first version](https://github.com/medz/napi/issues/31).

Acceptance is defined in the issues and [requirements](requirements.md). This release establishes the complete Dart-to-import workflow with a deliberately small API.

## Next

- [#26: Future<T> → Promise<T>](https://github.com/medz/napi/issues/26).
- [#27: Independent Node-API host compatibility](https://github.com/medz/napi/issues/27).
- [#28: Broader tested compiler/runtime support](https://github.com/medz/napi/issues/28).

Classes, JavaScript callbacks, and zero-copy buffers need demand and explicit ownership contracts before scheduling. No date is promised for deferred features.
